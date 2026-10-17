# -*- coding: utf-8 -*-
"""English/Japanese speaking-practice backend (FastAPI). Contract: ../API.md

Run:  .venv\\Scripts\\python.exe server.py            (serves on 127.0.0.1:<port>)
      .venv\\Scripts\\python.exe server.py --prefetch (download/verify all models, then exit)
"""
import os
import sys
import json
import time
import hashlib
import logging
import threading
import re
import unicodedata
import difflib
import math
import random
import subprocess
import llm_common   # LlmError + JSON helpers shared by the remote engines
import llm_opencode   # "opencode" engine: `opencode serve` + free DeepSeek V4.1 Flash (the default engine)
import llm_api        # "openai_api" engine: OpenAI-compatible HTTP APIs (OpenCode Zen, DeepSeek, Gemini, OpenRouter)
import llm_cache     # persistent cache of deterministic AI results (fix, translate, verify, gloss)
import llm_fallback   # remote engine usage-limit -> local Ollama fallback state
import grammar        # offline grammar correction (LanguageTool child process)
from io import BytesIO
from logging.handlers import RotatingFileHandler

BASE = os.path.dirname(os.path.abspath(__file__))
HF_DIR = os.path.join(BASE, "models", "hf")
LOG_DIR = os.path.join(BASE, "logs")
CACHE_DIR = os.path.join(BASE, "cache", "tts")
CONFIG_PATH = os.path.join(BASE, "config.json")
CURRICULUM_PATH = os.path.join(BASE, "curriculum.json")
os.makedirs(HF_DIR, exist_ok=True)
os.makedirs(LOG_DIR, exist_ok=True)
os.makedirs(CACHE_DIR, exist_ok=True)

# Everything the HF libraries download stays inside backend\models\hf
os.environ["HF_HOME"] = HF_DIR
os.environ["HF_HUB_CACHE"] = HF_DIR
os.environ["HF_HUB_DISABLE_SYMLINKS_WARNING"] = "1"
os.environ["HF_HUB_DISABLE_TELEMETRY"] = "1"
os.environ["TOKENIZERS_PARALLELISM"] = "false"
PREFETCH = "--prefetch" in sys.argv


def _arg(name, default=None):
    """--name value from the command line (dev/test overrides; nothing is saved to config.json)"""
    if name in sys.argv:
        i = sys.argv.index(name)
        if i + 1 < len(sys.argv):
            return sys.argv[i + 1]
    return default


# A second test server can run beside the app's: --port 8781 --tag w2 --stt-cpu
ARG_PORT = _arg("--port")
ARG_TAG = _arg("--tag")
ARG_STT_CPU = "--stt-cpu" in sys.argv
LOG_NAME = "server-%s.log" % ARG_TAG if ARG_TAG else "server.log"
if not PREFETCH:
    os.environ["HF_HUB_OFFLINE"] = "1"  # models are local after setup; never wait on the network

# pythonw has no stdout/stderr; many libs (tqdm, warnings) write to them.
if sys.stdout is None or sys.stderr is None:
    _fh = open(os.path.join(LOG_DIR, LOG_NAME), "a", encoding="utf-8", buffering=1)
    if sys.stdout is None:
        sys.stdout = _fh
    if sys.stderr is None:
        sys.stderr = _fh
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

# cuBLAS 12 / cuDNN 9 DLLs from the pip wheels (needed by ctranslate2 on Windows)
try:
    import site
    _dirs = list(site.getsitepackages())
    for _sp in _dirs:
        for _sub in ("cublas", "cudnn", "cuda_nvrtc"):
            _b = os.path.join(_sp, "nvidia", _sub, "bin")
            if os.path.isdir(_b):
                os.add_dll_directory(_b)
                os.environ["PATH"] = _b + os.pathsep + os.environ.get("PATH", "")
except Exception:
    pass

import warnings
warnings.filterwarnings("ignore")

import numpy as np
import requests
import soundfile as sf
from math import gcd
from scipy.signal import resample_poly
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse, Response
from fastapi.exceptions import RequestValidationError
from starlette.exceptions import HTTPException as StarletteHTTPException
from pydantic import BaseModel
from typing import List, Optional, Any
import lan   # phone link: extra LAN listener, pairing, device tokens (API.md "휴대폰 연결")

# ----------------------------------------------------------------------------------------------
# logging
# ----------------------------------------------------------------------------------------------
log = logging.getLogger("backend")
log.setLevel(logging.INFO)
if not log.handlers:
    _h = RotatingFileHandler(os.path.join(LOG_DIR, LOG_NAME), maxBytes=2_000_000, backupCount=3, encoding="utf-8")
    _h.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(message)s"))
    log.addHandler(_h)
    if sys.stderr is not None and sys.stderr.isatty():
        _sh = logging.StreamHandler(sys.stderr)
        _sh.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(message)s"))
        log.addHandler(_sh)

# ----------------------------------------------------------------------------------------------
# config
# ----------------------------------------------------------------------------------------------
DEFAULT_CONFIG = {
    "port": 8770,
    "llm_model": "qwen3:8b",
    "ollama_url": "http://127.0.0.1:11434",
    "keep_alive": "30m",
    "num_ctx": 6144,
    "stt": {"model": "small", "device": "cuda", "compute_type": "int8_float16"},
    "tts": {"voice_en": "af_heart", "voice_ja": "jf_alpha", "device": "auto", "cache_max_mb": 300},
    # default AI engine: the free DeepSeek V4.1 Flash through OpenCode (local Ollama answers when it is unavailable)
    "llm_provider": "opencode",
    "opencode": {"model": "deepseek-v4.1-flash-free", "variant": "low"},
    "lan": dict(lan.DEFAULT_LAN),   # phone link (off by default): enabled, port, discovery, discovery_port, name. No tokens here.
}
_cfg_lock = threading.Lock()


def load_config():
    cfg = json.loads(json.dumps(DEFAULT_CONFIG))
    try:
        with open(CONFIG_PATH, "r", encoding="utf-8-sig") as f:
            user = json.load(f)
        for k, v in user.items():
            if isinstance(v, dict) and isinstance(cfg.get(k), dict):
                cfg[k].update(v)
            else:
                cfg[k] = v
    except FileNotFoundError:
        pass
    except Exception:
        log.exception("config.json unreadable, using defaults")
    return cfg


_OVERRIDES = {}   # config path -> value forced by a command-line flag (--port, --stt-cpu, --ollama-url, --llm-model)


def _cli_override(path, value):
    """set CFG[path...] = value for this run only: save_config() never writes it to config.json"""
    node = CFG
    for k in path[:-1]:
        node = node[k]
    node[path[-1]] = value
    _OVERRIDES[path] = value


def _persistable(cfg):
    """cfg without the command-line overrides: a value that is still the forced one goes back to what config.json holds
    (or the default)"""
    out = json.loads(json.dumps(cfg))
    try:
        with open(CONFIG_PATH, "r", encoding="utf-8-sig") as f:
            disk = json.load(f)
    except Exception:
        disk = {}
    for path, forced in _OVERRIDES.items():
        node = out
        for k in path[:-1]:
            node = node.get(k) if isinstance(node, dict) else None
        if not isinstance(node, dict) or node.get(path[-1]) != forced:
            continue   # changed since (e.g. the user picked another engine in the app): that is a real change
        for src in (disk, DEFAULT_CONFIG):
            cur = src
            for k in path:
                cur = cur.get(k) if isinstance(cur, dict) else None
            if cur is not None:
                node[path[-1]] = cur
                break
        else:
            node.pop(path[-1], None)
    return out, disk


def save_config(cfg):
    with _cfg_lock:
        out, disk = _persistable(cfg)
        if out == disk:
            return   # nothing to change: leave the file (and its formatting) alone
        tmp = CONFIG_PATH + ".tmp"
        with open(tmp, "w", encoding="utf-8", newline="\n") as f:
            json.dump(out, f, ensure_ascii=False, indent=2)
        os.replace(tmp, CONFIG_PATH)


CFG = load_config()
if CFG.get("llm_provider") in ("claude_cli", "codex_cli", "gemini_cli"):  # migration: the CLI engines were removed
    CFG["llm_provider"] = "opencode"
    CFG.pop("cli_models", None)
    if not ARG_PORT:
        save_config(CFG)
if (CFG.get("openai_api") or {}).get("key_source") == "opencode":  # migration: the app no longer reads OpenCode's login key
    CFG["openai_api"]["key_source"] = "secret"
    if not ARG_PORT:
        save_config(CFG)
if _arg("--ollama-url"):  # test servers: point the local model at another (e.g. a closed) port
    _cli_override(("ollama_url",), _arg("--ollama-url"))
if ARG_PORT:
    _cli_override(("port",), int(ARG_PORT))
if ARG_STT_CPU:
    _cli_override(("stt", "device"), "cpu")
    _cli_override(("stt", "compute_type"), "int8")
if _arg("--llm-model"):  # test servers: compare local models without touching config.json
    _cli_override(("llm_model",), _arg("--llm-model"))
    _cli_override(("llm_provider",), "ollama")


class ApiError(Exception):
    def __init__(self, msg, status=400, format_error=False):
        self.msg = msg
        self.status = status
        self.format_error = format_error   # the AI answered, but not with a usable JSON object (ollama_json asks once more)


def need_lang(lang):
    if lang not in ("en", "ja"):
        raise ApiError("lang은 'en' 또는 'ja'여야 해요.", 400)
    return lang


# ----------------------------------------------------------------------------------------------
# audio decode
# ----------------------------------------------------------------------------------------------
def decode_audio_b64(b64: str) -> np.ndarray:
    import base64
    if not b64:
        raise ApiError("녹음된 소리가 없어요. 다시 녹음해 주세요.", 400)
    try:
        raw = base64.b64decode(b64, validate=False)
    except Exception:
        raise ApiError("오디오 데이터를 읽을 수 없어요.", 400)
    try:
        data, sr = sf.read(BytesIO(raw), dtype="float32", always_2d=True)
        mono = data.mean(axis=1)
    except Exception:
        try:
            from faster_whisper.audio import decode_audio
            return decode_audio(BytesIO(raw), sampling_rate=16000).astype(np.float32)
        except Exception:
            raise ApiError("오디오 형식을 읽을 수 없어요. WAV 파일을 보내 주세요.", 400)
    if sr != 16000 and len(mono):
        g = gcd(int(sr), 16000)
        mono = resample_poly(mono, 16000 // g, int(sr) // g).astype(np.float32)
    return np.ascontiguousarray(mono, dtype=np.float32)


# ----------------------------------------------------------------------------------------------
# STT (faster-whisper)
# ----------------------------------------------------------------------------------------------
_stt_model = None
_stt_lock = threading.Lock()      # guards loading
_stt_run_lock = threading.Lock()  # one transcription at a time
_stt_info = {"device": None, "compute_type": None}


def _load_whisper(device, compute_type):
    from faster_whisper import WhisperModel
    m = WhisperModel(CFG["stt"]["model"], device=device, compute_type=compute_type,
                     download_root=os.path.join(HF_DIR, "whisper"))
    # DLL problems on CUDA only show at the first inference, so test it here.
    silence = np.zeros(16000, dtype=np.float32)
    segs, _ = m.transcribe(silence, language="en", beam_size=1)
    list(segs)
    return m


def get_stt():
    global _stt_model
    if _stt_model is not None:
        return _stt_model
    with _stt_lock:
        if _stt_model is not None:
            return _stt_model
        t0 = time.time()
        want_dev = CFG["stt"]["device"]
        want_ct = CFG["stt"]["compute_type"]
        tries = []
        if want_dev == "cuda":
            tries.append(("cuda", want_ct))
            tries.append(("cpu", "int8"))
        else:
            tries.append(("cpu", "int8"))
        last = None
        for dev, ct in tries:
            try:
                _stt_model = _load_whisper(dev, ct)
                _stt_info.update(device=dev, compute_type=ct)
                log.info("Whisper loaded on %s/%s in %.1fs", dev, ct, time.time() - t0)
                if (dev != CFG["stt"]["device"] or ct != CFG["stt"]["compute_type"]) and not (ARG_PORT or ARG_STT_CPU):
                    CFG["stt"]["device"], CFG["stt"]["compute_type"] = dev, ct
                    try:
                        save_config(CFG)
                    except Exception:
                        log.exception("could not save config")
                return _stt_model
            except Exception as e:
                last = e
                log.warning("Whisper load failed on %s/%s: %s", dev, ct, e)
        raise ApiError("음성 인식 모델을 불러오지 못했어요: %s" % last, 503)


def transcribe(audio: np.ndarray, lang: str):
    """returns (text, words[{w,p,start,end}], duration)"""
    model = get_stt()
    duration = float(len(audio)) / 16000.0
    if len(audio) < 1600 or float(np.max(np.abs(audio))) < 0.003:
        return "", [], duration
    with _stt_run_lock:
        segs, _info = model.transcribe(
            audio, language=lang, task="transcribe", beam_size=5, temperature=0.0,
            word_timestamps=True, vad_filter=True, condition_on_previous_text=False,
            initial_prompt=None)
        segs = list(segs)
    words = []
    texts = []
    for s in segs:
        texts.append(s.text.strip())
        for w in (s.words or []):
            t = w.word.strip()
            if not t:
                continue
            words.append({"w": t, "p": round(float(min(1.0, max(0.0, w.probability))), 4),
                          "start": round(float(w.start), 3), "end": round(float(w.end), 3)})
    text = ("" if lang == "ja" else " ").join(x for x in texts if x).strip()
    return text, words, round(duration, 3)


# ----------------------------------------------------------------------------------------------
# TTS (Kokoro)
# ----------------------------------------------------------------------------------------------
_tts_pipes = {}
_tts_lock = threading.Lock()
_tts_ready = {"en": False, "ja": False}
_tts_device = ""          # "cpu" / "cuda" once Kokoro is loaded ("" = not loaded yet); shown in /health as tts_device
_espeak_patched = False
TTS_MIN_FREE_VRAM_MB = 1536   # Kokoro goes to the GPU only when at least this much VRAM is free at load time


def _patch_espeak_for_nonascii_path():
    """espeak-ng on Windows cannot open a data dir whose absolute path has non-ASCII characters
    (this project lives under a Korean folder name). Work around it by chdir-ing into the folder that
    contains espeak-ng-data and handing espeak the relative path '.'."""
    global _espeak_patched
    if _espeak_patched:
        return
    import espeakng_loader
    d = espeakng_loader.get_data_path()
    try:
        d.encode("ascii")
        ascii_ok = True
    except UnicodeEncodeError:
        ascii_ok = False
    if not ascii_ok:
        os.chdir(os.path.dirname(d))
        import phonemizer.backend.espeak.wrapper as W
        _orig = W.EspeakAPI
        W.EspeakAPI = lambda lib, dp: _orig(lib, ".")
    _espeak_patched = True


def pick_tts_device():
    """'cuda' only if config allows it, torch has CUDA and >= 1.5 GB VRAM is free right now; otherwise 'cpu'."""
    want = str(CFG["tts"].get("device", "auto") or "auto").lower()
    if want == "cpu":
        return "cpu", "config says cpu"
    try:
        import torch
        if not torch.cuda.is_available():
            return "cpu", "torch %s has no CUDA (CPU-only build)" % torch.__version__
        free, _total = torch.cuda.mem_get_info()
        free_mb = free / 1048576.0
        if free_mb >= TTS_MIN_FREE_VRAM_MB:
            return "cuda", "%.0f MB VRAM free" % free_mb
        return "cpu", "only %.0f MB VRAM free (< %d MB)" % (free_mb, TTS_MIN_FREE_VRAM_MB)
    except Exception as e:
        return "cpu", "cuda probe failed: %s" % e


def get_tts(lang):
    global _tts_device
    p = _tts_pipes.get(lang)
    if p is not None:
        return p
    with _tts_lock:
        p = _tts_pipes.get(lang)
        if p is not None:
            return p
        t0 = time.time()
        try:
            _patch_espeak_for_nonascii_path()
            from kokoro import KPipeline
            code = "a" if lang == "en" else "j"
            device, why = pick_tts_device()
            try:
                p = KPipeline(lang_code=code, repo_id="hexgrad/Kokoro-82M", device=device)
            except Exception:
                if device != "cuda":
                    raise
                log.exception("Kokoro %s failed on cuda, retrying on cpu", lang)
                device, why = "cpu", "cuda load failed"
                p = KPipeline(lang_code=code, repo_id="hexgrad/Kokoro-82M", device=device)
            voice = CFG["tts"]["voice_en" if lang == "en" else "voice_ja"]
            # warm up (loads the voice file and G2P)
            for _ in p("Hello." if lang == "en" else "こんにちは。", voice=voice, speed=1.0):
                pass
        except Exception as e:
            log.exception("TTS load failed (%s)", lang)
            raise ApiError("음성 합성 모델을 불러오지 못했어요 (%s): %s" % (lang, e), 503)
        _tts_pipes[lang] = p
        _tts_ready[lang] = True
        _tts_device = device
        log.info("Kokoro %s ready in %.1fs on %s (%s)", lang, time.time() - t0, device, why)
        return p


# ---- voices (only the voice packs that are already on disk; nothing is downloaded) -----------------------
VOICE_PREFIX = {"en": "a", "ja": "j"}   # Kokoro lang_code 'a' = American English voices (af_/am_), 'j' = Japanese (jf_/jm_)


def _voice_files():
    import glob
    root = os.path.join(HF_DIR, "models--hexgrad--Kokoro-82M", "snapshots")
    return sorted(glob.glob(os.path.join(root, "*", "voices", "*.pt")))


def default_voice(lang):
    return CFG["tts"]["voice_en" if lang == "en" else "voice_ja"]


def available_voices(lang):
    ids = []
    for f in _voice_files():
        vid = os.path.splitext(os.path.basename(f))[0]
        if re.fullmatch(r"[a-z]{2}_[a-z0-9]+", vid) and vid[0] == VOICE_PREFIX[lang] and vid not in ids:
            ids.append(vid)
    d = default_voice(lang)
    ids.sort(key=lambda v: (v != d, v))
    return ids


def voices_info():
    out = {}
    for lang in ("en", "ja"):
        lst = []
        for vid in available_voices(lang):
            lst.append({"id": vid, "name": vid.split("_", 1)[1].capitalize(),
                        "gender": "female" if vid[1] == "f" else "male", "default": vid == default_voice(lang)})
        out[lang] = lst
    return {"voices": out, "default": {"en": default_voice("en"), "ja": default_voice("ja")}}


def resolve_voice(lang, voice):
    """The requested voice if its pack is present locally, else the default (never triggers a download)."""
    voice = (voice or "").strip()
    if not voice or voice == default_voice(lang):
        return default_voice(lang)
    if voice in available_voices(lang):
        return voice
    log.warning("tts voice %r is not available locally for %s; using %s", voice, lang, default_voice(lang))
    return default_voice(lang)


# ---- on-disk cache with LRU eviction ----------------------------------------------------------------------
def _cache_dir():
    return os.environ.get("LANG_TTS_CACHE_DIR") or CACHE_DIR


def _cache_cap_bytes():
    env = os.environ.get("LANG_TTS_CACHE_MAX_MB")
    mb = float(env) if env else float(CFG["tts"].get("cache_max_mb", 300))
    return int(mb * 1048576)


_cache_lock = threading.Lock()
_cache_bytes = None      # running total of *.wav in the cache dir (None = not scanned yet)


def _cache_scan():
    files = []
    d = _cache_dir()
    os.makedirs(d, exist_ok=True)
    for name in os.listdir(d):
        if not name.endswith(".wav"):
            continue
        p = os.path.join(d, name)
        try:
            st = os.stat(p)
            files.append((st.st_mtime, st.st_size, p))
        except OSError:
            pass
    return files


def cache_evict(keep=None):
    """Delete least-recently-used clips (mtime = last access) until the cache is <= 90 % of the cap.
    Called once at server start and after every write that pushes it over the cap."""
    global _cache_bytes
    cap = _cache_cap_bytes()
    with _cache_lock:
        files = _cache_scan()
        try:   # stale temp files from a crashed write
            for name in os.listdir(_cache_dir()):
                if ".tmp" in name:
                    tp = os.path.join(_cache_dir(), name)
                    if time.time() - os.path.getmtime(tp) > 3600:
                        os.remove(tp)
        except OSError:
            pass
        total = sum(s for _m, s, _p in files)
        if total > cap:
            target = int(cap * 0.9)
            n = 0
            for _m, s, p in sorted(files):
                if total <= target:
                    break
                if keep and os.path.abspath(p) == os.path.abspath(keep):
                    continue
                try:
                    os.remove(p)
                    total -= s
                    n += 1
                except OSError:
                    pass
            log.info("tts cache: evicted %d clips, now %.1f MB (cap %.0f MB)", n, total / 1048576.0, cap / 1048576.0)
        _cache_bytes = total
        return total


def _cache_note_write(path, size):
    global _cache_bytes
    if _cache_bytes is None:
        cache_evict(keep=path)
        return
    with _cache_lock:
        _cache_bytes += size
        over = _cache_bytes > _cache_cap_bytes()
    if over:
        cache_evict(keep=path)


def _cache_touch(path):
    try:
        os.utime(path, None)   # last access = now (LRU)
    except OSError:
        pass


# ---- synthesis with in-flight de-duplication ---------------------------------------------------------------
_inflight = {}
_inflight_lock = threading.Lock()


def tts_key(text, lang, speed, voice):
    return hashlib.sha1(("%s|%s|%.3f|%s" % (text, lang, speed, voice)).encode("utf-8")).hexdigest()


def _synth_now(text, lang, speed, voice):
    pipe = get_tts(lang)
    chunks = []
    with _tts_lock:
        for _g, _ph, audio in pipe(text, voice=voice, speed=speed):
            if audio is not None:
                chunks.append(np.asarray(audio, dtype=np.float32).reshape(-1))
    if not chunks:
        raise ApiError("이 문장은 음성으로 만들 수 없었어요.", 422)
    pcm = np.concatenate(chunks)
    buf = BytesIO()
    sf.write(buf, pcm, 24000, format="WAV", subtype="PCM_16")
    return buf.getvalue()


def _wav_ok(data: bytes) -> bool:
    """A cached clip must be a complete RIFF/WAVE file with at least a header and some samples."""
    return (len(data) > 44 and data[:4] == b"RIFF" and data[8:12] == b"WAVE"
            and int.from_bytes(data[4:8], "little") + 8 <= len(data) + 1)


def synth_wav(text: str, lang: str, speed: float, voice: str = None) -> bytes:
    text = (text or "").strip()
    if not text:
        raise ApiError("읽어 줄 문장이 비어 있어요.", 400)
    text = text[:800]
    speed = float(speed if speed is not None else 1.0)
    speed = max(0.6, min(1.3, speed))
    voice = resolve_voice(lang, voice)
    key = tts_key(text, lang, speed, voice)
    path = os.path.join(_cache_dir(), key + ".wav")
    t0 = time.time()
    while True:
        try:
            with open(path, "rb") as f:
                data = f.read()
            if _wav_ok(data):
                _cache_touch(path)
                log.info("tts cache hit %s %s %.2f %s '%s'", lang, voice, speed, key[:8], text[:30])
                return data
            # a zero-byte or truncated file (crash, disk full) would otherwise be served forever
            log.warning("tts cache file broken (%d bytes), re-synthesizing %s", len(data), key[:8])
            try:
                os.remove(path)
            except OSError:
                pass
        except FileNotFoundError:
            pass
        with _inflight_lock:
            job = _inflight.get(key)
            mine = job is None
            if mine:
                job = _inflight[key] = {"ev": threading.Event(), "data": None, "err": None}
        if not mine:
            job["ev"].wait(120)
            if job["err"] is not None:
                raise job["err"]
            if job["data"] is not None:
                log.info("tts in-flight join %s %s %.2f %s '%s' waited %.2fs", lang, voice, speed, key[:8], text[:30], time.time() - t0)
                return job["data"]
            continue   # owner vanished or timed out: re-check the cache, then try ourselves
        break
    try:
        # the owner of a finished job may have written the file between our cache check and registration
        data = None
        if os.path.exists(path):
            with open(path, "rb") as f:
                data = f.read()
            if not _wav_ok(data):
                data = None
        if data is None:
            data = _synth_now(text, lang, speed, voice)
            try:
                os.makedirs(_cache_dir(), exist_ok=True)
                tmp = path + ".tmp%d" % threading.get_ident()
                with open(tmp, "wb") as f:
                    f.write(data)
                os.replace(tmp, path)
                _cache_note_write(path, len(data))
            except Exception:
                log.exception("tts cache write failed")
            log.info("tts synth %s %s %.2f %s '%s' %.2fs", lang, voice, speed, key[:8], text[:30], time.time() - t0)
        job["data"] = data
        return data
    except BaseException as e:
        job["err"] = e
        raise
    finally:
        with _inflight_lock:
            _inflight.pop(key, None)
        job["ev"].set()


# ---- splitting a reply into spoken chunks (the Godot app has an identical splitter: scripts/autoload/tts.gd) ----
_EN_ABBR = {"mr", "mrs", "ms", "dr", "prof", "sr", "jr", "st", "vs", "etc", "e.g", "i.e", "u.s", "no", "mt", "inc", "ltd", "approx"}
_CLOSERS = set("\"'”’)]」』）】")
_EN_TERM = set(".!?")
_JA_TERM = set("。！？!?")


_PUNCT = set("!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~…—–“”‘’「」『』（）【】。、！？・〜～:;")


def _has_letters(s):
    return any(not c.isspace() and c not in _PUNCT for c in s)


def split_sentences(text, lang):
    """en: split after . ! ? (followed by space/end); ja: after 。！？ (and ASCII ! ?). Newlines always split."""
    out = []
    for line in str(text).replace("\r", "\n").split("\n"):
        line = " ".join(line.split()) if lang == "en" else line.strip()
        if not line:
            continue
        cur = ""
        i, n = 0, len(line)
        term = _EN_TERM if lang == "en" else _JA_TERM
        while i < n:
            ch = line[i]
            cur += ch
            i += 1
            if ch not in term:
                continue
            j = i
            while j < n and (line[j] in term or line[j] in _CLOSERS):
                cur += line[j]
                j += 1
            if lang == "en":
                if j < n and line[j] != " ":
                    i = j      # e.g. 3.5 or "...)x": not a boundary
                    continue
                if ch == "." and j == i:   # a single '.' may be an abbreviation or an initial
                    tok = cur.rstrip().rsplit(" ", 1)[-1].lstrip("\"'“‘([")
                    base = tok.rstrip(".").lower()
                    if base in _EN_ABBR or (len(base) == 1 and base.isalpha() and tok[:1].isupper() and base not in ("i", "a")):
                        i = j
                        continue
            if lang == "ja" and j < n and line[j] == "と":   # 「…。」と言いました: the quote continues
                i = j
                continue
            i = j
            out.append(cur.strip())
            cur = ""
            while i < n and line[i] == " ":
                i += 1
        if cur.strip():
            out.append(cur.strip())
    merged = []
    for s in out:
        if merged and not _has_letters(s):
            merged[-1] += (" " if lang == "en" else "") + s
        else:
            merged.append(s)
    if len(merged) > 1 and not _has_letters(merged[0]):
        merged[1] = merged[0] + (" " if lang == "en" else "") + merged[1]
        merged.pop(0)
    return merged


def first_clause_split(s, lang):
    """Latency: Kokoro on CPU needs ~0.25 s per second of audio, so a long first sentence is cut at a clause
    boundary (, ; : / 、) so the first sound starts sooner. The tail must still be ready by the time the head has
    played (tail length <= ~3.5 x head length). Returns [head, tail] or [s]."""
    if lang == "en":
        words = s.split(" ")
        if len(s) >= 30 and len(words) >= 6:
            for k in range(2, min(10, len(words) - 2) + 1):
                if words[k - 1] != "" and words[k - 1][-1] in ",;:":
                    head, tail = " ".join(words[:k]), " ".join(words[k:])
                    if len(head) >= 8 and len(tail) <= 3.5 * len(head) + 8:
                        return [head, tail]
    else:
        if len(s) >= 12:
            for p, ch in enumerate(s):
                if ch == "、" and 5 <= p + 1 <= 14 and len(s) - (p + 1) >= 4 and len(s) - (p + 1) <= 3.5 * (p + 1) + 3:
                    return [s[:p + 1], s[p + 1:]]
    return [s]


def tts_chunks(text, lang):
    sents = split_sentences(text, lang)
    if not sents:
        return []
    return first_clause_split(sents[0], lang) + sents[1:]


def presynth_reply(reply, lang, speed, voice):
    """Start synthesizing a chat reply in the background (first chunk first) into the TTS cache, so the app's /tts
    requests are cache hits or join the in-flight job."""
    chunks = tts_chunks(reply, lang)
    if not chunks:
        return chunks

    def run():
        for c in chunks:
            try:
                synth_wav(c, lang, speed, voice)
            except Exception:
                log.warning("presynth failed for %r", c[:40], exc_info=True)
                return
    threading.Thread(target=run, name="presynth", daemon=True).start()
    return chunks


# ----------------------------------------------------------------------------------------------
# Japanese helpers (pyopenjtalk)
# ----------------------------------------------------------------------------------------------
_ojt = None
_ojt_lock = threading.Lock()
KATA_RE = re.compile(r"[ァ-ヶー]")
SMALL_KANA = set("ャュョァィゥェォヮ")


def ojt():
    global _ojt
    if _ojt is None:
        with _ojt_lock:
            if _ojt is None:
                import pyopenjtalk
                pyopenjtalk.g2p("テスト", kana=True)
                _ojt = pyopenjtalk
    return _ojt


def kata_only(s: str) -> str:
    return "".join(KATA_RE.findall(s))


def ja_to_kata(text: str) -> str:
    text = unicodedata.normalize("NFKC", text or "")
    if not text.strip():
        return ""
    return kata_only(ojt().g2p(text, kana=True))


# Chinese-only (simplified) forms and Chinese particles that models leak into Japanese text -> the Japanese equivalent
# ("" = drop). Only used when pyopenjtalk cannot read the character; a character that is not in the table is dropped.
SIMP_TO_JA = {
    "买": "買", "卖": "売", "说": "説", "话": "話", "请": "請", "谢": "謝", "对": "対", "时": "時", "间": "間", "开": "開",
    "关": "関", "问": "問", "题": "題", "觉": "覚", "见": "見", "现": "現", "样": "様", "电": "電", "车": "車", "东": "東",
    "饭": "飯", "书": "書", "读": "読", "写": "写", "听": "聞", "钱": "銭", "国": "国", "学": "学", "来": "来", "个": "個",
    "们": "達", "为": "為", "运": "運", "动": "動", "难": "難", "过": "過", "还": "", "这": "", "那": "", "么": "", "什": "",
    "吗": "か", "呢": "ね", "吧": "ね", "啊": "ね", "喝": "飲", "吃": "食", "没": "", "会": "会", "页": "頁", "机": "機",
    "热": "熱", "爱": "愛", "两": "両", "岁": "歳", "实": "実", "际": "際", "业": "業", "务": "務", "发": "発",
}
# ideographs: CJK extension A, the main block, compatibility ideographs (﨑 U+FA11) and the extension B-G planes (𠮷 U+20BB7)
HAN_ANY = re.compile(r"[\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff\U00020000-\U0003134f]")
# Japanese variant forms (names!) OpenJTalk's dictionary may not know -> the standard form, for the READING only
VARIANT_TO_STD = {"髙": "高", "﨑": "崎", "𠮷": "吉", "邉": "辺", "邊": "辺", "濵": "浜", "德": "徳", "栁": "柳", "冨": "富", "桒": "桑",
                  "圓": "円", "眞": "真", "說": "説", "渕": "淵", "彅": "剛", "曻": "昇", "槇": "槙", "增": "増"}
# simplified characters that Japanese does not use although JIS/cp932 also contain them (so the GB2312 test misses them)
SIMP_EXTRA = "气怎你您她们这吗呢吧啊么没还请说话谢对时间开关问题觉见现样电车东饭书读听钱为运动难过热爱两岁实际业务发吃喝买卖"


def _encodes(c, codec):
    try:
        c.encode(codec)
        return True
    except UnicodeEncodeError:
        return False


def is_chinese_only(c):
    """a simplified-Chinese character that Japanese does not use: listed in SIMP_TO_JA / SIMP_EXTRA, or in GB 2312 but in
    neither cp932 (JIS X 0208 + NEC/IBM extensions) nor JIS X 0213.
    Variant forms of Japanese names (髙 﨑 𠮷 邉 ...), old forms (國 體 學) and ordinary kanji are NOT Chinese-only."""
    if not ("\u4e00" <= c <= "\u9fff") or c in VARIANT_TO_STD:
        return False
    return c in SIMP_TO_JA or c in SIMP_EXTRA or (_encodes(c, "gb2312") and not _encodes(c, "cp932") and not _encodes(c, "euc_jis_2004"))


# what a hiragana reading may contain: kana, long-vowel mark, punctuation, the ___ blank, spaces
JA_READING_CHARS = re.compile(r"[ぁ-ゖゝゞー、。，．・…！？!?.,:;~〜\-「」『』（）()\[\]\"'_＿\s]")


def ja_text_foreign(text: str):
    """characters of a Japanese string that OpenJTalk cannot read although they are CJK ideographs, i.e. Chinese-only
    characters (买 吗 这 ...) that leaked into the model's Japanese. [] for clean Japanese."""
    text = unicodedata.normalize("NFKC", text or "")
    bad = []
    if not HAN_ANY.search(text):
        return bad
    try:
        for m in ojt().run_frontend(text):
            st, r = m.get("string", ""), m.get("read") or ""
            if HAN_ANY.search(st) and not re.fullmatch(r"[ァ-ヶー]+", r):
                bad.extend(c for c in st if is_chinese_only(c))
    except Exception:
        log.exception("ja_text_foreign failed")
    return bad


def ja_fix_foreign(text: str) -> str:
    """replace the Chinese-only characters found by ja_text_foreign with their Japanese form, or drop them"""
    bad = set(ja_text_foreign(text))
    if not bad:
        return text
    return "".join((SIMP_TO_JA.get(c, "") if c in bad else c) for c in text)


def ja_reading(text: str) -> str:
    """hiragana reading (spelling form: は stays は) of a Japanese string; punctuation kept, ___ kept, spaces dropped.
    Characters OpenJTalk cannot read (Chinese-only ideographs) are replaced by their Japanese form when known, else dropped,
    so the result never contains ideographs."""
    import jaconv
    text = text or ""
    if not text.strip():
        return ""
    parts = []
    for seg in re.split(r"(___)", text):
        if seg == "___":
            parts.append("___")
            continue
        if not seg.strip():
            continue
        try:
            seg = "".join(VARIANT_TO_STD.get(c, c) for c in unicodedata.normalize("NFKC", seg))   # name variants first
            seg = ja_fix_foreign(seg)
            for m in ojt().run_frontend(seg):
                r = m.get("read") or ""
                st = m.get("string", "")
                if re.fullmatch(r"[ァ-ヶー]+", r):
                    parts.append(jaconv.kata2hira(r))
                elif st.strip():
                    parts.append(HAN_ANY.sub("", st.strip()))
        except Exception:
            log.exception("ja_reading failed")
    out = "".join(parts)
    return out.replace(",", "、").replace(".", "。").replace("!", "！").replace("?", "？")


def fix_ja_reading(reading, source: str) -> str:
    """A reading that may come from an AI: kept if it is clean (kana, punctuation, spaces only); if it is empty or mixed
    with other characters (e.g. "わたしは买います"), it is rebuilt locally from the Japanese `source` text."""
    r = (reading or "").strip() if isinstance(reading, str) else ""
    if r and all(JA_READING_CHARS.fullmatch(c) for c in r):
        return r
    return "".join(c for c in ja_reading(source) if JA_READING_CHARS.fullmatch(c))  # last resort: allowed characters only


def has_kanji_or_kata(s):
    return bool(re.search(r"[一-鿿゠-ヿ]", s or ""))


def split_mora(kana: str):
    out = []
    for ch in kana:
        if ch in SMALL_KANA and out:
            out[-1] += ch
        else:
            out.append(ch)
    return out


# ----------------------------------------------------------------------------------------------
# text normalisation
# ----------------------------------------------------------------------------------------------
_CONTR = {
    "can't": "can not", "cannot": "can not", "won't": "will not", "shan't": "shall not", "ain't": "is not",
    "let's": "let us", "gonna": "going to", "wanna": "want to", "gotta": "got to", "y'all": "you all",
    "ma'am": "madam", "o'clock": "oclock", "gimme": "give me", "lemme": "let me", "kinda": "kind of",
}
_S_IS = {"it", "that", "what", "there", "here", "who", "he", "she", "where", "how", "when", "why", "this", "everything", "something", "nothing", "someone", "everyone"}


def _expand_contraction(w: str):
    if w in _CONTR:
        return _CONTR[w].split()
    if w.endswith("n't") and len(w) > 3:
        return [w[:-3], "not"]
    for suf, full in (("'m", "am"), ("'re", "are"), ("'ve", "have"), ("'ll", "will"), ("'d", "would")):
        if w.endswith(suf) and len(w) > len(suf):
            return [w[: -len(suf)], full]
    if w.endswith("'s") and len(w) > 2:
        base = w[:-2]
        return [base, "is"] if base in _S_IS else [base]
    return [w.replace("'", "")] if w.endswith("'") else [w]


def _num_words(w: str):
    try:
        from num2words import num2words
        if w.isdigit() and len(w) <= 9:
            return re.sub(r"[^a-z ]", " ", num2words(int(w))).split()
    except Exception:
        pass
    return [w]


def en_words(text: str):
    s = unicodedata.normalize("NFKC", text or "").lower().replace("’", "'").replace("‘", "'").replace("`", "'")
    s = s.replace("-", " ").replace("–", " ").replace("—", " ")
    s = re.sub(r"(?<=\d),(?=\d{3}\b)", "", s)
    s = re.sub(r"[^a-z0-9' ]+", " ", s)
    out = []
    for w in s.split():
        w = w.strip("'") if w.strip("'") else ""
        if not w:
            continue
        for x in _expand_contraction(w):
            x = x.strip("'")
            if not x:
                continue
            out.extend(_num_words(x))
    return out


def norm_text(s: str, lang: str) -> str:
    s = unicodedata.normalize("NFKC", s or "").lower()
    if lang == "en":
        return " ".join(en_words(s))
    return re.sub(r"[\s、。，．,.!?！？「」『』（）()…・〜~\"'：:；;]", "", s)


# ----------------------------------------------------------------------------------------------
# alignment
# ----------------------------------------------------------------------------------------------
def nw_align(a, b, sim):
    """global alignment; returns list of (i|None, j|None)"""
    n, m = len(a), len(b)
    GAP = -0.5
    sc = [[0.0] * (m + 1) for _ in range(n + 1)]
    bt = [[0] * (m + 1) for _ in range(n + 1)]
    for i in range(1, n + 1):
        sc[i][0] = i * GAP
        bt[i][0] = 1
    for j in range(1, m + 1):
        sc[0][j] = j * GAP
        bt[0][j] = 2
    for i in range(1, n + 1):
        for j in range(1, m + 1):
            d = sc[i - 1][j - 1] + sim(a[i - 1], b[j - 1]) - 0.45
            u = sc[i - 1][j] + GAP
            l = sc[i][j - 1] + GAP
            best = max(d, u, l)
            sc[i][j] = best
            bt[i][j] = 0 if best == d else (1 if best == u else 2)
    i, j, out = n, m, []
    while i > 0 or j > 0:
        t = bt[i][j]
        if i > 0 and j > 0 and t == 0:
            out.append((i - 1, j - 1)); i -= 1; j -= 1
        elif i > 0 and (t == 1 or j == 0):
            out.append((i - 1, None)); i -= 1
        else:
            out.append((None, j - 1)); j -= 1
    out.reverse()
    return out


def align_seq(target, heard, sim):
    """SequenceMatcher on the sequences; replace blocks are re-aligned with nw_align.
    returns (pairs, inserts): pairs[i] = (heard_idx|None, exact: bool) for each target index;
    inserts = list of (before_target_index, heard_idx) for extra heard items."""
    sm = difflib.SequenceMatcher(None, target, heard, autojunk=False)
    pairs = [(None, False)] * len(target)
    pairs = list(pairs)
    inserts = []
    for op, i1, i2, j1, j2 in sm.get_opcodes():
        if op == "equal":
            for k in range(i2 - i1):
                pairs[i1 + k] = (j1 + k, True)
        elif op == "replace":
            for ti, hj in nw_align(target[i1:i2], heard[j1:j2], sim):
                if ti is not None and hj is not None:
                    pairs[i1 + ti] = (j1 + hj, False)
                elif hj is not None:
                    inserts.append((i1 + (ti if ti is not None else 0), j1 + hj))
        elif op == "insert":
            for hj in range(j1, j2):
                inserts.append((i1, hj))
    return pairs, inserts


def word_sim(a, b):
    return difflib.SequenceMatcher(None, a, b).ratio()


_VOICE_PAIRS = {}
for _u, _v in (("カキクケコ", "ガギグゲゴ"), ("サシスセソ", "ザジズゼゾ"), ("タチツテト", "ダヂヅデド"), ("ハヒフヘホ", "バビブベボ"), ("パピプペポ", "バビブベボ")):
    for _x, _y in zip(_u, _v):
        _VOICE_PAIRS[(_x, _y)] = (_x, _y)
        _VOICE_PAIRS[(_y, _x)] = (_x, _y)
_ROW = {}
for _grp in ("アイウエオ", "カキクケコ", "ガギグゲゴ", "サシスセソ", "ザジズゼゾ", "タチツテト", "ダヂヅデド", "ナニヌネノ", "ハヒフヘホ", "バビブベボ", "パピプペポ", "マミムメモ", "ヤユヨ", "ラリルレロ", "ワヲ"):
    for _i, _c in enumerate(_grp):
        _ROW[_c] = (_grp, _i)


def mora_sim(a, b):
    if a == b:
        return 1.0
    ra, rb = _ROW.get(a[0]), _ROW.get(b[0])
    if ra and rb:
        if ra[0] == rb[0]:
            return 0.4
        if ra[1] == rb[1] and len(ra[0]) == len(rb[0]) == 5:
            return 0.4  # same vowel
        if (a[0], b[0]) in _VOICE_PAIRS:
            return 0.7
    return 0.0


# ----------------------------------------------------------------------------------------------
# scoring
# ----------------------------------------------------------------------------------------------
OK_PROB = 0.45
NO_VOICE_TIP = "목소리가 들리지 않았어요. 마이크를 확인하고 조금 더 크게 말해 보세요."


def fluency_score(lang, n_units, words):
    if not words:
        return 0
    span = max(0.01, words[-1]["end"] - words[0]["start"])
    if lang == "en":
        lo, hi, rate = 1.8, 3.5, len(words) / span
        short = len(words) <= 2
    else:
        lo, hi, rate = 4.0, 8.0, n_units / span
        short = n_units <= 4
    if short or span < 0.6:
        rate_score = 100.0
    elif rate < lo:
        rate_score = 100.0 * max(0.0, rate / lo)
    elif rate > hi:
        rate_score = max(0.0, 100.0 - (rate - hi) / hi * 60.0)
    else:
        rate_score = 100.0
    pen = 0.0
    for a, b in zip(words, words[1:]):
        gap = b["start"] - a["end"]
        if gap > 0.8:
            pen += 12.0 + min(25.0, (gap - 0.8) * 15.0)
    return int(round(max(0.0, min(100.0, rate_score - pen))))


def _final_score(accuracy, clarity, fluency):
    return int(round(0.6 * accuracy + 0.25 * clarity + 0.15 * fluency))


# ---- English tips ----
_EN_TOK = re.compile(r"th|sh|ch|ee|ea|oo|[a-z]")
_EN_RULES = {
    ("r", "l"): ("rl", "r은 혀끝을 입천장에 대지 않고 뒤로 살짝 말아 올려요. 한국어 ㄹ처럼 혀를 대면 l로 들려요."),
    ("l", "r"): ("rl", "l은 혀끝을 윗니 뒤 잇몸에 붙인 채로 소리를 내요. 혀를 말면 r로 들려요."),
    ("f", "p"): ("fp", "f는 윗니를 아랫입술에 살짝 대고 바람을 새게 내는 소리예요. 입술을 붙였다 터뜨리면 p가 돼요."),
    ("p", "f"): ("fp", "p는 두 입술을 붙였다가 터뜨리는 소리예요. 윗니를 입술에 대지 마세요."),
    ("v", "b"): ("vb", "v는 윗니를 아랫입술에 살짝 대고 목을 울려요. 입술을 붙이면 b로 들려요."),
    ("b", "v"): ("vb", "b는 두 입술을 붙였다 터뜨리는 소리예요. 윗니를 입술에 대면 v로 들려요."),
    ("th", "s"): ("th", "th는 혀끝을 윗니와 아랫니 사이에 살짝 내밀고 바람을 내요. 혀를 안으로 넣으면 s로 들려요."),
    ("th", "d"): ("th", "th는 혀끝을 윗니와 아랫니 사이에 살짝 내밀고 바람을 내요. 혀를 입천장에 붙이면 d로 들려요."),
    ("th", "t"): ("th", "th는 혀끝을 윗니와 아랫니 사이에 살짝 내밀고 바람을 내요. 혀를 입천장에 붙이면 t로 들려요."),
    ("th", "z"): ("th", "th는 혀끝을 윗니와 아랫니 사이에 살짝 내밀고 바람을 내요. 혀를 안으로 넣으면 z로 들려요."),
    ("z", "j"): ("zj", "z는 혀를 윗잇몸 가까이에 두고 목을 울리며 바람을 내보내요. 혀를 붙였다 떼면 j로 들려요."),
    ("j", "z"): ("zj", "j는 혀를 윗잇몸에 붙였다가 떼며 소리를 내요. 바람만 내보내면 z로 들려요."),
    ("i", "ee"): ("vowel", "짧은 i(ship)와 긴 ee(sheep)를 구분해야 해요. 짧은 i는 입 힘을 풀고 짧게 발음해요."),
    ("i", "ea"): ("vowel", "짧은 i(ship)와 긴 ee(sheep)를 구분해야 해요. 짧은 i는 입 힘을 풀고 짧게 발음해요."),
    ("ee", "i"): ("vowel", "긴 ee(sheep)는 입꼬리를 옆으로 당기고 길게 끌어 발음해요. 짧게 하면 i(ship)로 들려요."),
    ("ea", "i"): ("vowel", "긴 ee(sheep)는 입꼬리를 옆으로 당기고 길게 끌어 발음해요. 짧게 하면 i(ship)로 들려요."),
    ("u", "oo"): ("vowel", "짧은 u(full)와 긴 oo(fool)를 구분해야 해요. 짧은 u는 입술을 덜 내밀고 짧게 발음해요."),
    ("oo", "u"): ("vowel", "긴 oo(fool)는 입술을 동그랗게 내밀고 길게 끌어 발음해요. 짧게 하면 u(full)로 들려요."),
    ("a", "e"): ("vowel", "a와 e 모음이 헷갈렸어요. a(bad)는 입을 더 크게 벌려 발음해요."),
    ("e", "a"): ("vowel", "e와 a 모음이 헷갈렸어요. e(bed)는 입을 덜 벌리고 발음해요."),
}


def _en_tokens(w):
    return _EN_TOK.findall(w)


def en_tip_for_pair(t, h):
    """returns (category, tip) for target word t heard as h, or None"""
    ta, hb = _en_tokens(t), _en_tokens(h)
    sm = difflib.SequenceMatcher(None, ta, hb, autojunk=False)
    for op, i1, i2, j1, j2 in sm.get_opcodes():
        if op == "replace":
            a, b = "".join(ta[i1:i2]), "".join(hb[j1:j2])
            if (a, b) in _EN_RULES:
                cat, msg = _EN_RULES[(a, b)]
                return cat, "'%s'가 '%s'로 들렸어요. %s" % (t, h, msg)
    # dropped final consonant(s)
    if len(h) < len(t) and t.startswith(h) and len(t) - len(h) <= 2 and not set(t[len(h):]) & set("aeiou"):
        tail = t[len(h):]
        if len(h) < 3:
            return None
        if tail in ("s", "es"):
            return "final", "'%s'가 '%s'로 들렸어요. 끝의 복수형 s 소리가 빠졌어요. 단어 끝 s를 또렷하게 내 주세요." % (t, h)
        if tail in ("ed", "d") and len(h) >= 3:
            return "final", "'%s'가 '%s'로 들렸어요. 끝의 -ed(d/t) 소리가 빠졌어요. 단어 끝 자음까지 살려서 발음해 주세요." % (t, h)
        return "final", "'%s'가 '%s'로 들렸어요. 단어 끝 자음 '%s'가 빠졌어요. 받침처럼 끝 자음까지 짧게 소리 내 주세요." % (t, h, tail)
    return None


def en_tips(units, fluency, clarity, lang_words):
    tips, seen = [], set()
    generic = []
    for u in units:
        if u["ok"]:
            continue
        if u["heard"]:
            r = en_tip_for_pair(u["t"], u["heard"]) if word_sim(u["t"], u["heard"]) >= 0.5 else None
            if r:
                if r[0] not in seen:
                    seen.add(r[0]); tips.append(r[1])
                continue
            generic.append("'%s'가 '%s'로 들렸어요." % (u["t"], u["heard"]))
        else:
            generic.append("'%s'가 잘 들리지 않았어요." % u["t"])
    out = tips[:3]
    if len(out) < 3 and generic:
        missed = [u["t"] for u in units if not u["ok"]][:4]
        if len(generic) == 1:
            out.append(generic[0] + " 그 단어만 따로 천천히 연습한 뒤 문장으로 이어 보세요.")
        else:
            out.append("놓치거나 다르게 들린 단어: %s. 이 단어들을 먼저 따로 연습한 뒤 문장으로 이어 말해 보세요." % ", ".join("'%s'" % m for m in missed))
    out = out[:3]
    if len(out) < 3 and fluency < 70 and lang_words:
        out.append("말 속도나 멈춤이 고르지 않았어요. 문장을 한 호흡으로 자연스럽게 이어서 말해 보세요.")
    if len(out) < 3 and not out and clarity < 70:
        out.append("전체적으로 또렷함이 조금 부족해요. 입을 크게 벌리고 단어 끝까지 또박또박 말해 보세요.")
    return out[:3]


# ---- Japanese tips ----
def _h(s):
    import jaconv
    return jaconv.kata2hira(s)


def ja_tip_for_pair(t, h):
    """t: target mora, h: heard mora (katakana)"""
    if t == "ッ":
        return "sokuon", "촉음 'っ'가 빠졌어요. 'っ' 자리에서 소리를 한 박 멈췄다가 다음 소리를 내 주세요 (예: きて / きって)."
    if (t, h) in _VOICE_PAIRS or (t[0], h[0]) in _VOICE_PAIRS and t[1:] == h[1:]:
        if t[0] in "カキクケコサシスセソタチツテトハヒフヘホパピプペポ":
            return "voice", "'%s'가 '%s'로 들렸어요. 첫소리가 탁음으로 바뀌었어요. 성대를 울리지 말고 숨만 내보내며 발음하세요." % (_h(t), _h(h))
        return "voice", "'%s'가 '%s'로 들렸어요. 탁음은 성대를 울려서 발음해야 해요. 청음(か·さ·た·は)과 구분해 주세요." % (_h(t), _h(h))
    if t == "ツ" and h in ("チュ", "ス", "チ", "ト", "トゥ"):
        return "tsu", "'つ'가 '%s'로 들렸어요. つ는 혀끝을 윗니 뒤에 붙였다 떼며 'ㅊ'과 'ㅅ' 사이처럼 내는 소리예요. '츠'와 비슷하지만 입술을 내밀지 마세요." % _h(h)
    if t == "ズ" and h in ("ジュ", "ジ", "ス", "ヅ"):
        return "zu", "'ず'가 '%s'로 들렸어요. ず는 혀를 윗잇몸 가까이에 두고 성대를 울리며 내는 소리예요. '주'가 아니라 '즈'에 가까워요." % _h(h)
    if t in ("ー",):
        return "long", "장음 'ー'가 짧게 들렸어요. 모음을 한 박 더 길게 끌어 주세요 (예: おばさん / おばあさん)."
    return None


def ja_tips(units, tmoras, ins_marks, fluency, clarity, heard_n):
    tips, seen = [], set()
    # per-unit rules
    for u in units:
        if u["ok"]:
            continue
        t_k = u["_k"]
        h_k = u["_hk"]
        if t_k == "ー":
            u["_cov"] = True
            if "long" not in seen:
                seen.add("long")
                tips.append("장음 'ー'가 짧게 들렸어요. 모음을 한 박 더 길게 끌어 주세요 (예: おばさん / おばあさん).")
            continue
        r = ja_tip_for_pair(t_k, h_k) if h_k else (ja_tip_for_pair(t_k, "") if t_k == "ッ" else None)
        if r:
            u["_cov"] = True
            if r[0] not in seen:
                seen.add(r[0]); tips.append(r[1])
    for mark in ins_marks:
        if mark == "ー" and "longx" not in seen:
            seen.add("longx")
            tips.append("짧게 끝내야 할 곳이 길게 늘어났어요. 장음이 아닌 곳은 한 박으로 짧게 발음해 주세요.")
        elif mark == "ッ" and "sokx" not in seen:
            seen.add("sokx")
            tips.append("촉음 'っ'가 없어야 할 곳에서 들렸어요. 소리를 멈추지 말고 이어서 발음해 보세요.")
    out = tips[:3]
    if len(out) < 3:
        missed = []
        for u in units:
            if not u["ok"] and not u.get("_cov") and u["t"] not in missed:
                missed.append(u["t"])
        if missed:
            out.append("놓치거나 다르게 들린 소리: %s. 이 부분을 천천히 따로 연습한 뒤 문장으로 이어 말해 보세요." % ", ".join("'%s'" % m for m in missed[:5]))
    out = out[:3]
    if len(out) < 3 and fluency < 70 and heard_n:
        out.append("말 속도나 멈춤이 고르지 않았어요. 일본어는 박(모라)을 일정한 리듬으로 이어서 말하면 자연스러워요.")
    if len(out) < 3 and not out and clarity < 70:
        out.append("전체적으로 또렷함이 조금 부족해요. 입을 크게 벌리고 한 글자씩 또박또박 말해 보세요.")
    return out[:3]


def mismatch_tip(text):
    return "목표 문장과 많이 다르게 들렸어요 (들린 문장: \"%s\"). 화면의 문장을 보면서 천천히 또박또박 따라 읽어 보세요." % text


def empty_score(units):
    return {"transcript": "", "score": 0, "accuracy": 0, "clarity": 0, "fluency": 0, "units": units, "tips_ko": [NO_VOICE_TIP]}


def score_en(target, words, text):
    tw = en_words(target)
    if not tw:
        raise ApiError("연습할 문장이 비어 있어요.", 400)
    hw = []  # (norm word, prob)
    for w in words:
        for x in en_words(w["w"]):
            hw.append((x, w["p"]))
    if not hw:
        return empty_score([{"t": t, "ok": False, "conf": 0.0, "heard": None} for t in tw])
    pairs, _ins = align_seq(tw, [x for x, _ in hw], word_sim)
    units = []
    for i, t in enumerate(tw):
        j, exact = pairs[i]
        if j is not None and exact:
            p = hw[j][1]
            units.append({"t": t, "ok": p >= OK_PROB, "conf": round(p, 3), "heard": None, "_m": True})
        elif j is not None:
            units.append({"t": t, "ok": False, "conf": 0.0, "heard": hw[j][0], "_m": False})
        else:
            units.append({"t": t, "ok": False, "conf": 0.0, "heard": None, "_m": False})
    n = len(units)
    accuracy = 100.0 * sum(1 for u in units if u["ok"]) / n
    matched = [u for u in units if u["_m"]]
    clarity = 100.0 * (sum(u["conf"] for u in matched) / len(matched)) if matched else 0.0
    fluency = fluency_score("en", n, words)
    tips = en_tips(units, fluency, clarity, words)
    if accuracy < 40:
        tips = ([mismatch_tip(text)] + tips)[:3]
    for u in units:
        u.pop("_m", None)
    return {"transcript": text, "score": _final_score(accuracy, clarity, fluency), "accuracy": int(round(accuracy)),
            "clarity": int(round(clarity)), "fluency": fluency, "units": units, "tips_ko": tips}


def _ja_heard_moras(words):
    """list of (mora, prob) for transcript words, context-aware via full-sentence frontend."""
    joined = "".join(w["w"] for w in words)
    char_word = []
    for wi, w in enumerate(words):
        char_word.extend([wi] * len(w["w"]))
    out = []
    try:
        morphs = ojt().run_frontend(unicodedata.normalize("NFKC", joined))
        total = sum(len(m["string"]) for m in morphs)
        if total != len(joined):
            raise ValueError("offset mismatch")
        pos = 0
        for m in morphs:
            s = m["string"]
            ms = split_mora(kata_only(m.get("pron", "")))
            if ms:
                for k, mo in enumerate(ms):
                    cp = min(pos + int(k * len(s) / len(ms)), len(joined) - 1)
                    out.append((mo, words[char_word[cp]]["p"]))
            pos += len(s)
        return out
    except Exception:
        out = []
        for w in words:
            for mo in split_mora(ja_to_kata(w["w"])):
                out.append((mo, w["p"]))
        return out


def score_ja(target, reading, words, text):
    src = (reading or "").strip() or target
    tk = ja_to_kata(src)
    tm = split_mora(tk)
    if not tm:
        raise ApiError("연습할 문장이 비어 있어요.", 400)
    if not words:
        return empty_score([{"t": _h(m), "ok": False, "conf": 0.0, "heard": None} for m in tm])
    hm = _ja_heard_moras(words)
    if not hm:
        return empty_score([{"t": _h(m), "ok": False, "conf": 0.0, "heard": None} for m in tm])
    pairs, inserts = align_seq(tm, [m for m, _ in hm], mora_sim)
    units = []
    for i, t in enumerate(tm):
        j, exact = pairs[i]
        if j is not None and exact:
            p = hm[j][1]
            units.append({"t": _h(t), "ok": p >= OK_PROB, "conf": round(p, 3), "heard": None, "_k": t, "_hk": "", "_m": True})
        elif j is not None:
            units.append({"t": _h(t), "ok": False, "conf": 0.0, "heard": _h(hm[j][0]), "_k": t, "_hk": hm[j][0], "_m": False})
        else:
            units.append({"t": _h(t), "ok": False, "conf": 0.0, "heard": None, "_k": t, "_hk": "", "_m": False})
    n = len(units)
    accuracy = 100.0 * sum(1 for u in units if u["ok"]) / n
    matched = [u for u in units if u["_m"]]
    clarity = 100.0 * (sum(u["conf"] for u in matched) / len(matched)) if matched else 0.0
    fluency = fluency_score("ja", len(hm), words)
    ins_marks = [hm[j][0] for _b, j in inserts if hm[j][0] in ("ー", "ッ")]
    if accuracy < 40:
        tips = [mismatch_tip(text)]
    else:
        tips = ja_tips(units, tm, ins_marks, fluency, clarity, len(hm))
    for u in units:
        for k in ("_k", "_hk", "_m", "_cov"):
            u.pop(k, None)
    return {"transcript": text, "score": _final_score(accuracy, clarity, fluency), "accuracy": int(round(accuracy)),
            "clarity": int(round(clarity)), "fluency": fluency, "units": units, "tips_ko": tips}


# ----------------------------------------------------------------------------------------------
# curriculum + LLM
# ----------------------------------------------------------------------------------------------
_curriculum = None


def get_curriculum():
    global _curriculum
    if _curriculum is None:
        with open(CURRICULUM_PATH, "r", encoding="utf-8-sig") as f:
            _curriculum = json.load(f)
    return _curriculum


def plain(s):
    return str(s or "").replace("**", "").replace("`", "")


def clamp_int(v, lo, hi, default):
    try:
        v = int(v)
    except Exception:
        return default
    return max(lo, min(hi, v))


LEVEL = {
    "en": ["", "CEFR A2. Use very common words and short sentences. Speak simply and clearly.",
           "CEFR B1. Everyday natural English, short to medium sentences, avoid rare idioms.",
           "CEFR B1+. Natural conversational English with some common phrasal verbs.",
           "CEFR B2. Natural native speed and expressions, occasional idioms."],
    "ja": ["", "JLPT N5. Use only です/ます form, very basic vocabulary and short sentences. Use only very common kanji.",
           "JLPT N5-N4. Polite form by default, everyday vocabulary, short sentences.",
           "JLPT N4. Use casual speech if the scene is casual between friends; otherwise polite.",
           "JLPT N3. Natural spoken Japanese with common colloquial expressions."],
}
LNAME = {"en": "English", "ja": "Japanese"}


def context_text(lang, n, w):
    months = get_curriculum()[lang]["months"]
    m = next((x for x in months if x["n"] == n), months[0])
    wk = m["weeks"][(w or 1) - 1] if 0 <= (w or 1) - 1 < len(m["weeks"]) else m["weeks"][0]
    content = " | ".join((c["k"] + ": " if c.get("k") else "") + plain(c["v"]) for c in m["content"])[:1500]
    return 'Curriculum month %d topic: "%s". This week: "%s" (%s). Month content: %s' % (n, plain(m["title"]), plain(wk["topic"]), plain(wk["act"]), content)


def stage_of(month):
    return int(math.ceil(month / 3.0))


class LLMDown(Exception):
    pass


_llm_health = {"t": 0.0, "ok": False}


def llm_available():
    if llm_provider() == "opencode":
        return llm_opencode.available() or local_llm_ready()  # without OpenCode the local model answers
    if llm_provider() == "openai_api":
        return llm_api.has_key(llm_api.settings(CFG))
    now = time.time()
    if now - _llm_health["t"] < 5:
        return _llm_health["ok"]
    ok = False
    try:
        r = requests.get(CFG["ollama_url"] + "/api/tags", timeout=1.5)
        names = [m.get("name") or m.get("model") for m in r.json().get("models", [])]
        want = CFG["llm_model"]
        ok = want in names or (want + ":latest") in names
    except Exception:
        ok = False
    _llm_health.update(t=now, ok=ok)
    return ok


# AI engines: "opencode" (default: free DeepSeek V4.1 Flash through `opencode serve`), "ollama" (offline local model,
# also the automatic fallback), "openai_api" (any OpenAI-compatible API with a key; not shown in the app's picker)
ENGINES = ("opencode", "ollama", "openai_api")
ENGINE_LABEL = {"opencode": llm_opencode.LABEL, "ollama": "오프라인 로컬", "openai_api": "API 키 엔진"}


def llm_provider():
    p = CFG.get("llm_provider", "opencode")
    return p if p in ENGINES else "opencode"


def using_remote():
    """A remote engine is selected (OpenCode or the OpenAI-compatible API), not the local Ollama model."""
    return llm_provider() != "ollama"


def _opencode_json(messages, schema, temperature):
    """One-shot JSON answer from `opencode serve` (llm_opencode.py). Raises llm_common.LlmError."""
    try:
        data, dt, st = llm_opencode.call_json(CFG, messages, schema, temperature=temperature)
    except llm_common.LlmError as e:
        log.warning("opencode call failed (%s): %s | %s", e.kind, e.msg, (e.raw or "")[:200].replace("\n", " "))
        raise
    log.info("opencode call %.1fs %s", dt, st)
    _llm_health.update(t=time.time(), ok=True)
    return data


def _api_json(messages, schema, temperature, num_predict):
    """One OpenAI-compatible API call (llm_api.py). Raises llm_common.LlmError."""
    try:
        data, dt, model = llm_api.call_json(CFG, messages, schema, temperature=temperature, timeout=120)
    except llm_common.LlmError as e:
        log.warning("openai_api call failed (%s): %s | %s", e.kind, e.msg, (e.raw or "")[:200].replace("\n", " "))
        raise
    log.info("openai_api call %.1fs (%s)", dt, model)
    _llm_health.update(t=time.time(), ok=True)
    return data


def _remote_json(messages, schema, temperature, num_predict):
    if llm_provider() == "openai_api":
        return _api_json(messages, schema, temperature, num_predict)
    return _opencode_json(messages, schema, temperature)


def _remote_model():
    return llm_api.settings(CFG)["model"] if llm_provider() == "openai_api" else llm_opencode.model(CFG)


# ---- usage-limit fallback from the remote engine to the local model (llm_fallback.py) ----
_local_health = {"t": 0.0, "ok": False}


def _local_model_listed():
    """Ollama answers on ollama_url and has the configured model (no start attempt)."""
    try:
        r = requests.get(CFG["ollama_url"] + "/api/tags", timeout=1.5)
        names = [m.get("name") or m.get("model") for m in r.json().get("models", [])]
        want = CFG["llm_model"]
        return want in names or (want + ":latest") in names
    except Exception:
        return False


_local_start_fail_t = 0.0


def local_llm_ready():
    """The local Ollama model can answer. Starts Ollama if it is installed but not running (a failed start is not
    retried for 2 minutes, so a broken Ollama never stalls requests). Cached 10 s."""
    global _local_start_fail_t
    now = time.time()
    if now - _local_health["t"] < 10:
        return _local_health["ok"]
    ok = False
    if _ollama_installed() or not using_remote():
        if _local_model_listed():
            ok = True
        elif now - _local_start_fail_t > 120:
            ensure_ollama()
            ok = _local_model_listed()
            if not ok:
                _local_start_fail_t = time.time()
    _local_health.update(t=time.time(), ok=ok)
    return ok


_local_probe = {"t": 0.0, "ok": False}


def local_llm_reachable():
    """Like local_llm_ready() but never starts anything and answers fast (cached 5 s): for /health and GET /llm."""
    now = time.time()
    if now - _local_probe["t"] < 5:
        return _local_probe["ok"]
    ok = _local_model_listed()
    _local_probe.update(t=now, ok=ok)
    return ok


def remote_route_active():
    """True if AI calls go to the selected remote engine now; False if Ollama is selected, or the remote engine is
    unavailable / hit its limit and the local model can stand in until the reset time."""
    if not using_remote():
        return False
    if llm_provider() == "opencode" and not llm_opencode.available() and local_llm_ready():
        return False  # OpenCode not installed: the local model answers (see _fallback_status)
    return not (llm_fallback.active_for(llm_provider()) and local_llm_ready())


def on_remote_error(e):
    """Record a usage-limit / login failure of the remote engine. True if the request should be retried locally."""
    if not getattr(e, "kind", None):
        return False
    prov = llm_provider()
    llm_fallback.mark(prov, e.kind, e.raw, e.msg, label=ENGINE_LABEL.get(prov, prov))
    st = llm_fallback.status(prov)
    ok = local_llm_ready()
    log.warning("%s unusable (%s) until %s -> %s", prov, e.kind, st["until"],
                "using local model %s" % CFG["llm_model"] if ok else "local model NOT ready, no fallback")
    return ok


def _with_cache(kind, prov, model, messages, schema, opts, fn):
    if not kind:
        return fn()
    key = llm_cache.make_key(kind, prov, model, schema, messages, opts)
    hit = llm_cache.get(key)
    if hit is not None:
        log.info("llm cache HIT %s (%s/%s) %s", kind, prov, model, key[:12])
        return hit
    t0 = time.time()
    data = fn()
    llm_cache.put(key, kind, prov, model, data)
    log.info("llm cache MISS %s (%s/%s) %s stored after %.1fs", kind, prov, model, key[:12], time.time() - t0)
    return data


STRICT_JSON_NOTE = ("(Your previous answer could not be read as JSON. Answer again with ONLY one JSON object that matches the schema: "
                    "it starts with { and ends with }, no code fences, no text before or after it, no comments, double quotes around every key and string.)")


def ollama_json(messages, schema, temperature=0.7, num_predict=1800, think=False, cache_key_kind=None):
    """The single LLM entry point: the selected remote engine or local Ollama, with the usage-limit fallback.
    cache_key_kind: e.g. "fix", "translate", "verify", "gloss" -> the result is cached persistently (backend/cache/
    llm_cache.sqlite) by (kind, provider, model, schema, messages, options). Only for deterministic tasks; default off.
    An answer that holds no usable JSON object (after llm_common.extract_json's repairs) is asked for ONE more time with a
    stricter instruction; if that fails too, ApiError 502 (Korean message)."""
    try:
        return _ollama_json_once(messages, schema, temperature, num_predict, think, cache_key_kind)
    except ApiError as e:
        if not e.format_error:
            raise
        log.warning("AI answer was not usable JSON; asking once more with a stricter instruction")
    msgs = [dict(m) for m in messages]
    if msgs and msgs[-1].get("role") == "user":
        msgs[-1]["content"] = msgs[-1]["content"] + "\n\n" + STRICT_JSON_NOTE
    else:
        msgs.append({"role": "user", "content": STRICT_JSON_NOTE})
    return _ollama_json_once(msgs, schema, min(temperature, 0.3), num_predict, think, cache_key_kind)


def _ollama_json_once(messages, schema, temperature, num_predict, think, cache_key_kind):
    opts = {"temperature": temperature, "num_predict": num_predict, "think": think}
    if remote_route_active():
        try:
            return _with_cache(cache_key_kind, llm_provider(), _remote_model(), messages, schema, opts,
                               lambda: _remote_json(messages, schema, temperature, num_predict))
        except llm_common.LlmError as e:
            if not on_remote_error(e):
                raise ApiError(e.msg, e.status, format_error=llm_common.is_format_error(e))
    return _with_cache(cache_key_kind, "ollama", CFG["llm_model"], messages, schema, opts,
                       lambda: _ollama_chat_json(messages, schema, temperature, num_predict, think))


def _ollama_chat_json(messages, schema, temperature, num_predict, think):
    body = {
        "model": CFG["llm_model"], "messages": messages, "stream": False, "think": think,
        "format": schema, "keep_alive": CFG.get("keep_alive", "30m"),
        "options": {"temperature": temperature, "top_p": 0.9, "num_ctx": CFG.get("num_ctx", 6144), "num_predict": num_predict},
    }
    t0 = time.time()
    try:
        r = requests.post(CFG["ollama_url"] + "/api/chat", json=body, timeout=300)
        if r.status_code == 500 and "repeat" in r.text:  # model got stuck in a loop: retry once, hotter + random seed
            log.warning("ollama repeat abort, retrying")
            body["options"]["temperature"] = min(1.0, temperature + 0.25)
            body["options"]["seed"] = random.randint(1, 10**6)
            body["options"]["repeat_penalty"] = 1.1
            r = requests.post(CFG["ollama_url"] + "/api/chat", json=body, timeout=300)
    except requests.exceptions.ConnectionError:
        raise ApiError("AI 모델 서버(Ollama)에 연결할 수 없어요. Ollama가 실행 중인지 확인해 주세요.", 503)
    except requests.exceptions.Timeout:
        raise ApiError("AI 응답이 너무 오래 걸려요. 잠시 뒤에 다시 시도해 주세요.", 504)
    if r.status_code == 404:
        raise ApiError("AI 모델 '%s'이(가) 설치되어 있지 않아요. setup.ps1을 다시 실행해 주세요." % CFG["llm_model"], 503)
    if r.status_code != 200:
        log.warning("ollama %s: %s", r.status_code, r.text[:300])
        raise ApiError("AI 모델 호출에 실패했어요. 잠시 뒤에 다시 시도해 주세요.", 502)
    try:
        content = r.json()["message"]["content"]
        data = llm_common.extract_json(content)
    except Exception:
        log.warning("ollama returned non-JSON: %s", r.text[:500])
        raise ApiError(llm_common.FORMAT_MSG, 502, format_error=True)
    log.info("ollama call %.1fs (%d chars)", time.time() - t0, len(content))
    _llm_health.update(t=time.time(), ok=True)
    return data


def S(**props):
    return {"type": "object", "properties": props, "required": list(props.keys()), "additionalProperties": False}


STR = {"type": "string"}
FIX_SCHEMA = S(fix=STR, fix_ko=STR)
CHAT_SCHEMA = S(reply=STR, reading=STR, ko=STR,
                suggest={"type": "array", "items": STR, "minItems": 2, "maxItems": 2})
FEEDBACK_SCHEMA = S(
    scores=S(fluency={"type": "integer", "minimum": 1, "maximum": 5}, accuracy={"type": "integer", "minimum": 1, "maximum": 5},
             vocabulary={"type": "integer", "minimum": 1, "maximum": 5}),
    summary=STR,
    corrections={"type": "array", "maxItems": 6, "items": S(you=STR, better=STR, reading=STR, ko=STR, why=STR)},
    phrases={"type": "array", "minItems": 3, "maxItems": 5, "items": S(phrase=STR, reading=STR, ko=STR)})
INT = {"type": "integer", "minimum": 0, "maximum": 3}
LESSON_SCHEMA = S(title=STR, exercises={"type": "array", "minItems": 8, "maxItems": 10, "items": {"anyOf": [
    S(type={"const": "choice"}, question=STR, options={"type": "array", "items": STR, "minItems": 4, "maxItems": 4}, answer=INT, explain=STR),
    S(type={"const": "fill"}, sentence=STR, reading=STR, ko=STR, options={"type": "array", "items": STR, "minItems": 4, "maxItems": 4}, answer=INT, explain=STR),
    S(type={"const": "build"}, ko=STR, answer={"type": "array", "items": STR, "minItems": 3, "maxItems": 12}, extra={"type": "array", "items": STR, "minItems": 2, "maxItems": 2}, reading=STR, explain=STR),
    S(type={"const": "listen"}, audio=STR, reading=STR, options={"type": "array", "items": STR, "minItems": 4, "maxItems": 4}, answer=INT, explain=STR),
    S(type={"const": "speak"}, text=STR, reading=STR, ko=STR),
]}})

# ---- chat ----
SCENE_GENERIC_PERSONA = "a friendly native %s speaker (choose a natural name, job and city yourself)"
SCENE_GENERIC_SCENE = ("Choose a concrete everyday situation that lets the learner practice this month's topic and this week's focus. "
                       "Briefly set the scene in your first line.")


def rules_text(lang, scenario, stage, n, w):
    sc = scenario or {}
    sid = (sc.get("id") or "").strip()
    persona = (sc.get("persona") or "").strip()
    scene = (sc.get("scene") or "").strip()
    if sid == "month" or (not persona and not scene):
        persona = SCENE_GENERIC_PERSONA % LNAME[lang]
        scene = SCENE_GENERIC_SCENE
    else:
        if not persona:
            persona = "a friendly native %s speaker" % LNAME[lang]
        if not scene:
            scene = "A casual everyday conversation."
    title = (sc.get("title") or "").strip()
    return (
        "You are role-playing as a native " + LNAME[lang] + " speaker so a Korean learner can practice real conversation.\n"
        "Your persona: " + persona + ". Scene: " + scene + (" (Korean scenario title for reference: " + title + ")" if title else "") + "\n"
        "Learner level: " + LEVEL[lang][stage] + "\n" + context_text(lang, n, w) + "\n\n"
        "Rules:\n- Stay in character and talk like a real native speaker would in this situation, adjusted to the learner's level.\n"
        "- ALWAYS respond to the learner's last message first. If they asked a question, answer it in character before anything else; "
        "if they asked what a word or phrase means, explain it simply. Never ignore what they said.\n"
        "- Stay on the current topic and build on what was already said. Do not jump to an unrelated topic, and never repeat a question "
        "you already asked in this conversation. Move to a new topic only when the current one is naturally finished, with a smooth transition.\n"
        "- Keep each reply short (1-3 sentences) and usually end with a question or something that invites a reply, connected to the current topic.\n"
        "- \"reply\" is what your character says next, always in " + LNAME[lang] + ", never Korean. React to what the learner meant, even if their grammar was wrong; never point out mistakes in \"reply\".\n"
        "- If the learner writes in Korean or mixes in Korean, stay in character and answer naturally.\n"
        "- \"ko\" is the natural Korean translation of the WHOLE \"reply\", every sentence (Korean only, no Chinese characters).\n"
        "- \"suggest\": exactly 2 short, different things the learner could naturally say next, in " + LNAME[lang] + " at their level.\n"
        + ("- \"reading\": the full hiragana reading of \"reply\" (hiragana only).\n" if lang == "ja"
           else "- \"reading\" must be an empty string.\n")
        + "\nReply only with the JSON object."
    )


def clean_hist(history, limit=24):
    out = []
    for h in (history or [])[-limit:]:
        role = "ai" if (h.role or "").lower() in ("ai", "assistant", "partner") else "me"
        text = (h.text or "").strip()
        if text:
            out.append({"role": role, "text": text})
    return out


def valid_str_list(v, n=None):
    return isinstance(v, list) and all(isinstance(x, str) and x.strip() for x in v)


HANGUL = re.compile(r"[가-힣]")
HAN = re.compile(r"[一-鿿]")


def ko_ok(text, lang="en", required=True):
    """True if `text` looks like clean Korean (Hangul present; no stray Chinese characters leaking from the model)."""
    text = text or ""
    if not text.strip():
        return not required
    if not HANGUL.search(text):
        return False
    han = len(HAN.findall(text))
    if han and (lang == "en" or han > 0.15 * len(text)):
        return False
    if FOREIGN_SCRIPT.search(text):  # e.g. Cyrillic words leaking into the Korean translation
        return False
    return True


FOREIGN_SCRIPT = re.compile(r"[Ѐ-ӿ؀-ۿ฀-๿֐-׿Ͱ-Ͽ]")


def scrub_ko(text, lang="en"):
    """A Korean field the model mixed with Chinese characters (e.g. "안녕하세요!什么东西要买吗?"): when ko_ok() rejects it
    and there is Hangul in it, the ideographs / foreign-script letters are removed (and the brackets they leave empty);
    a text with no Hangul at all that is Chinese / foreign script becomes ""."""
    text = (text or "").strip()
    if not text:
        return text
    if not HANGUL.search(text):
        return "" if (HAN.search(text) or FOREIGN_SCRIPT.search(text)) else text
    if ko_ok(text, lang):
        return text
    cleaned = FOREIGN_SCRIPT.sub("", HAN.sub("", text))
    cleaned = re.sub(r"[(（\[【「]\s*[)）\]】」]", "", cleaned)
    cleaned = re.sub(r"\s{2,}", " ", cleaned).strip()
    return cleaned if HANGUL.search(cleaned) else ""


QUESTION_EN = re.compile(r"\?|\b(what|why|how|where|when|who|which|whose|can you|could you|do you|did you|are you|is it|mean|meaning)\b", re.I)
QUESTION_JA = re.compile(r"[？?]|ですか|ますか|でしょうか|って何|とは|どういう|なに|何|どう|どこ|いつ|だれ|誰|なぜ|どうして")


KO_SCHEMA ={"type": "object", "properties": {"ko": {"type": "string"}}, "required": ["ko"]}


def translate_ko(text, lang):
    """Focused translation call. Translating Japanese inside the role-play JSON was often wrong with the 8B model."""
    prompt = ("Translate this " + LNAME[lang] + " line from a conversation into natural Korean. Translate every sentence "
              "faithfully, keep the meaning and politeness level, and do not add or drop anything. Korean only.\n\n" + text +
              '\n\nReply with JSON: {"ko": "..."}')
    for attempt in range(2):
        try:
            d = ollama_json([{"role": "user", "content": prompt}], KO_SCHEMA, temperature=0.2 if attempt == 0 else 0.4, num_predict=400,
                            cache_key_kind="translate")
        except ApiError:
            return ""
        ko = str(d.get("ko", "") or "").strip()
        if ko_ok(ko, lang):
            return ko
    return ""


def looks_like_question(text, lang):
    return bool((QUESTION_EN if lang == "en" else QUESTION_JA).search(text or ""))


def correct_learner(lang, stage, text, prev_ai):
    """Is the learner's last sentence wrong/unnatural? returns (fix, fix_ko) or ("", "").
    1) LanguageTool (offline, grammar.py). If it fixes something, that alone is a valid answer; with an AI engine
       available, the AI may still polish the LanguageTool version for naturalness (config "grammar_llm_polish", default on).
    2) If LanguageTool finds nothing (or is not installed), the AI checks "grammatical but unnatural" as before."""
    lt = None
    try:
        lt = grammar.correct(lang, text)
    except Exception:
        log.exception("languagetool correction failed")
    if lt is None:
        try:
            return _llm_correct(lang, stage, text, prev_ai)
        except ApiError as e:   # no AI engine can answer (OpenCode missing/failing and Ollama unreachable): no fix, not an error
            log.info("no AI available for the correction (%s): no fix", e.msg)
            return "", ""
    if not CFG.get("grammar_llm_polish", True):
        return lt["fix"], lt["fix_ko"]
    try:
        f, fk = _llm_correct(lang, stage, text, prev_ai, lt_fix=lt["fix"])
    except ApiError as e:
        log.info("AI polish unavailable (%s): LanguageTool result only", e.msg)
        return lt["fix"], lt["fix_ko"]
    if not f or norm_text(f, lang) in (norm_text(lt["fix"], lang), norm_text(text, lang)):
        return lt["fix"], lt["fix_ko"]  # the AI agrees with LanguageTool: keep its rule-specific explanation
    log.info("AI polished LanguageTool fix %r -> %r", lt["fix"], f)
    return f, fk


def _llm_correct(lang, stage, text, prev_ai, lt_fix=""):
    ln = LNAME[lang]
    hint = ""
    if lt_fix:
        hint = ('An automatic grammar checker suggested this correction: "' + lt_fix + '". It is usually right about grammar but '
                "can miss other mistakes or sound unnatural. Put the best corrected natural version of the WHOLE sentence into "
                "\"fix\" (the checker's version unchanged if it is already correct and natural), and in \"fix_ko\" explain in "
                "one Korean line what was wrong in the learner's ORIGINAL sentence.\n\n")
    prompt = (
        "A Korean learner of " + ln + " (level: " + LEVEL[lang][stage] + ") said this in a conversation"
        + (' (the partner had just said: "' + prev_ai + '")' if prev_ai else "") + ':\n"' + text + '"\n\n' + hint +
        "If the sentence has a grammar, word-choice or spelling mistake, or sounds unnatural to a native speaker, put the corrected natural version of the WHOLE sentence "
        "in " + ln + " into \"fix\", and a one-line explanation written in Korean (한국어) into \"fix_ko\" saying what was wrong. "
        "If the learner wrote in Korean, put the natural " + ln + " way to say it into \"fix\". "
        "If the sentence is already correct and natural (capitalization and punctuation differences do not count), set both \"fix\" and \"fix_ko\" to empty strings. "
        "Do not rewrite correct sentences just to change the style. "
        "Check carefully: verb tense against time words (yesterday/昨日 needs past tense), particles (は/が/を/に/で), "
        "articles and plurals, subject-verb agreement, word order, and words that do not fit the meaning."
    )
    fix = ""
    for attempt in range(2):
        d = ollama_json([{"role": "user", "content": prompt}], FIX_SCHEMA, temperature=0.2 if attempt == 0 else 0.5, num_predict=2500, think=True,
                        cache_key_kind="fix")
        fix = str(d.get("fix", "") or "").strip()
        fix_ko = str(d.get("fix_ko", "") or "").strip()
        if not fix or norm_text(fix, lang) == norm_text(text, lang):
            return "", ""
        if (lang == "en" and HANGUL.search(fix)) or (lang == "ja" and not re.search(r"[\u3040-\u30ff\u4e00-\u9fff]", fix)):
            fix = ""
            continue
        if ko_ok(fix_ko, lang):
            return fix, fix_ko
    return (fix, "더 자연스럽게 고친 문장이에요.") if fix else ("", "")


def _chat_opencode(req, lang, sys_prompt):
    """Chat turn on one `opencode serve` session per conversation (llm_opencode.chat_json); None = use the normal path."""
    hist = clean_hist(req.history, limit=400)  # the session keeps its own context; only the new message is sent
    note = ""
    if hist and hist[-1]["role"] == "me":
        note = ("(The learner is asking you something here. Begin by answering it directly and simply, in character, "
                "then continue on the same topic. 1-3 sentences, JSON only.)" if looks_like_question(hist[-1]["text"], lang)
                else "(Respond directly to this message and stay on the same topic. 1-3 sentences, JSON only.)")
    try:
        data, dt, st = llm_opencode.chat_json(CFG, req.conv_id or "", sys_prompt, hist, note, CHAT_SCHEMA)
    except llm_common.LlmError as e:
        log.warning("opencode chat failed (%s): %s | %s", e.kind, e.msg, (e.raw or "")[:200].replace("\n", " "))
        if on_remote_error(e) or llm_common.is_format_error(e):   # a malformed answer: the next path asks again (strict JSON)
            return None
        raise ApiError(e.msg, e.status)
    log.info("opencode chat turn %.1fs %s", dt, st)
    _llm_health.update(t=time.time(), ok=True)
    return data if isinstance(data, dict) else {}


def run_chat(req):
    lang = need_lang(req.lang)
    stage = clamp_int(req.stage, 1, 4, stage_of(clamp_int(req.month, 1, 12, 1)))
    n = clamp_int(req.month, 1, 12, 1)
    w = clamp_int(req.week, 1, 4, 1)
    hist = clean_hist(req.history)
    sys_prompt = rules_text(lang, req.scenario or {}, stage, n, w)
    msgs = [{"role": "system", "content": sys_prompt}]
    if not hist:
        msgs.append({"role": "user", "content": "(The conversation starts now. Give your opening line.)"})
    else:
        if hist[0]["role"] == "ai":
            msgs.append({"role": "user", "content": "(The conversation starts now.)"})
        for i, h in enumerate(hist):
            text = h["text"]
            if i == len(hist) - 1 and h["role"] == "me":
                # small models drift on long chats; restate the key rule right next to the message they must answer
                if looks_like_question(text, lang):
                    text += ("\n\n(The learner is asking you something here. Your reply MUST begin by answering that question "
                             "directly and simply, in character. Only after answering may you continue the conversation on the "
                             "same topic. 1-3 sentences, JSON only.)")
                else:
                    text += ("\n\n(Reply in character: first respond directly to this message, stay on the same topic, "
                             "1-3 sentences, JSON only.)")
            msgs.append({"role": "assistant" if h["role"] == "ai" else "user", "content": text})
        if hist[-1]["role"] == "ai":
            msgs.append({"role": "user", "content": "(Continue the conversation naturally.)"})
    last_me = hist[-1]["text"] if hist and hist[-1]["role"] == "me" else ""
    prev_ai = ""
    if last_me and len(hist) >= 2 and hist[-2]["role"] == "ai":
        prev_ai = hist[-2]["text"][:300]
    reply = ko = ""
    data = {}
    oc_session = llm_provider() == "opencode" and remote_route_active()
    for attempt in range(2):
        data = _chat_opencode(req, lang, sys_prompt) if (oc_session and attempt == 0) else None
        if data is None:  # other engines, the retry, or the OpenCode limit fallback
            data = ollama_json(msgs, CHAT_SCHEMA, temperature=0.6 if attempt == 0 else 0.45, num_predict=600)
        reply = str(data.get("reply", "")).strip()
        ko = str(data.get("ko", "") or "").strip()
        bad = (not reply) or len(reply) < 2 or re.match(r"(?i)\s*fix", reply) is not None
        if lang == "ja" and HANGUL.search(reply) and not re.search(r"[\u3040-\u30ff\u4e00-\u9fff]", reply):
            bad = True
        if lang == "en" and HANGUL.search(reply):
            bad = True
        if lang == "ja" and not bad and ja_text_foreign(reply):   # e.g. 买 / 吗: Chinese-only characters in the Japanese
            bad = True
        if not ko_ok(ko, lang):
            bad = True
        if not bad:
            break
        log.info("chat attempt %d rejected: %r", attempt + 1, str(data)[:200])
    else:
        if not reply or (lang == "en" and HANGUL.search(reply)):
            raise ApiError("AI가 대답을 만들지 못했어요. 다시 시도해 주세요.", 502)
    if lang == "ja":
        reply = ja_fix_foreign(reply)   # still Chinese-only characters after the retry: Japanese form, or dropped
    # the reading is always made locally (pyopenjtalk is more exact than the model's own "reading"); fix_ja_reading
    # guarantees that it holds kana / punctuation only
    reading = fix_ja_reading(ja_reading(reply), reply) if lang == "ja" else ""
    if lang == "ja" and not remote_route_active():  # the remote models translate well inside the reply itself
        ko = translate_ko(reply, lang) or ko
    ko = scrub_ko(ko, lang)
    fix = fix_ko = ""
    if last_me and not req.skip_fix:
        fix, fix_ko = correct_learner(lang, stage, last_me, prev_ai)
    suggest = [x.strip() for x in (data.get("suggest") or []) if isinstance(x, str) and x.strip()][:2]
    return {"reply": reply, "reading": reading, "ko": ko, "fix": fix, "fix_ko": fix_ko, "suggest": suggest}


def run_feedback(req):
    lang = need_lang(req.lang)
    stage = clamp_int(req.stage, 1, 4, 1)
    hist = clean_hist(req.history, 40)
    mine = [h for h in hist if h["role"] == "me"]
    if not mine:
        raise ApiError("평가할 대화가 없어요. 먼저 한 마디 이상 말해 보세요.", 400)
    transcript = "\n".join(("Partner: " if h["role"] == "ai" else "Learner: ") + h["text"] for h in hist)[-12000:]
    ln = LNAME[lang]
    prompt = (
        "A Korean learner of " + ln + " (level: " + LEVEL[lang][stage] + ") just had this practice conversation:\n\n" + transcript + "\n\n"
        "Give feedback on the LEARNER's lines only. All explanations (summary, ko, why) must be natural Korean.\n"
        "- scores: integers 1-5 for fluency, accuracy, vocabulary.\n"
        "- summary: 2-3 Korean sentences: what went well and the one thing to improve.\n"
        "- corrections: up to 6 items, ONLY for real mistakes or clearly unnatural learner lines. \"you\" = the learner's original sentence, "
        "\"better\" = the natural " + ln + " version, \"ko\" = Korean meaning of \"better\", \"why\" = short Korean explanation. "
        "If there are no mistakes, use an empty list.\n"
        "- phrases: 3-5 useful " + ln + " expressions for this situation (\"phrase\" in " + ln + ", \"ko\" Korean meaning).\n"
        + ("- \"reading\" fields: full hiragana reading of \"better\" / \"phrase\" (hiragana only).\n" if lang == "ja" else "- \"reading\" fields must be empty strings.\n")
    )
    prompt += "IMPORTANT: \"summary\", every \"ko\" and every \"why\" MUST be written in Korean (한국어), not English.\n"
    for attempt in range(2):
        data = ollama_json([{"role": "user", "content": prompt}], FEEDBACK_SCHEMA, temperature=0.4 if attempt == 0 else 0.2, num_predict=1500)
        if isinstance(data, dict) and ko_ok(str(data.get("summary", "")), "en"):
            break
        log.info("feedback attempt %d: summary not Korean", attempt + 1)
    sc = data.get("scores") or {}
    scores = {k: clamp_int(sc.get(k), 1, 5, 3) for k in ("fluency", "accuracy", "vocabulary")}
    corr = []
    seen_c = set()
    for c in data.get("corrections") or []:
        if not isinstance(c, dict) or not str(c.get("better", "")).strip():
            continue
        better = str(c["better"]).strip()
        you = str(c.get("you", "")).strip()
        if norm_text(you, lang) == norm_text(better, lang) or (norm_text(you, lang), norm_text(better, lang)) in seen_c:
            continue
        seen_c.add((norm_text(you, lang), norm_text(better, lang)))
        rd = ja_reading(better) if lang == "ja" else ""
        corr.append({"you": you, "better": better, "reading": rd, "ko": scrub_ko(str(c.get("ko", "") or ""), lang), "why": scrub_ko(str(c.get("why", "") or ""), lang)})
    phr = []
    seen_p = set()
    for p in data.get("phrases") or []:
        if not isinstance(p, dict) or not str(p.get("phrase", "")).strip() or norm_text(str(p["phrase"]), lang) in seen_p:
            continue
        seen_p.add(norm_text(str(p["phrase"]), lang))
        ph = str(p["phrase"]).strip()
        rd = ja_reading(ph) if lang == "ja" else ""
        phr.append({"phrase": ph, "reading": rd, "ko": scrub_ko(str(p.get("ko", "") or ""), lang)})
    return {"scores": scores, "summary": scrub_ko(str(data.get("summary", "") or ""), "en"), "corrections": corr[:6], "phrases": phr[:5]}


# ---- lesson ----
def valid_ex(e):
    if not isinstance(e, dict):
        return False
    opts = e.get("options")
    ans = e.get("answer")
    opts_ok = (isinstance(opts, list) and len(opts) >= 2 and all(isinstance(o, str) and o.strip() for o in opts)
               and isinstance(ans, int) and not isinstance(ans, bool) and 0 <= ans < len(opts))
    t = e.get("type")
    if t == "choice":
        return opts_ok and isinstance(e.get("question"), str) and e["question"].strip() != ""
    if t == "fill":
        return opts_ok and isinstance(e.get("sentence"), str) and "___" in e["sentence"]
    if t == "listen":
        return opts_ok and isinstance(e.get("audio"), str) and e["audio"].strip() != ""
    if t == "build":
        return (isinstance(ans, list) and len(ans) >= 2 and all(isinstance(x, str) and x.strip() for x in ans))
    if t == "speak":
        return isinstance(e.get("text"), str) and e["text"].strip() != ""
    return False


def finish_ex(e, lang):
    """normalise a valid exercise: shuffle options, dedupe, fill missing readings."""
    t = e["type"]
    out = {"type": t}
    s = lambda k: str(e.get(k, "") or "").strip()
    def jf(x):   # Chinese-only characters in the AI's Japanese: swapped for their Japanese form; no Japanese form -> "" (dropping it would leave a broken sentence)
        if lang != "ja":
            return x
        bad = set(ja_text_foreign(x))
        if not bad:
            return x.strip()
        if any(not SIMP_TO_JA.get(c) for c in bad):
            return ""
        return ja_fix_foreign(x).strip()
    if t in ("choice", "fill", "listen"):
        opts = [jf(re.sub(r"^\s*[A-Da-d1-4][\.\)．）:]\s+", "", o).strip()) for o in e["options"]]
        if not all(opts):   # an option that was only Chinese-only characters is gone
            return None
        correct = opts[e["answer"]]
        uniq = []
        for o in opts:
            if o not in uniq:
                uniq.append(o)
        if len(uniq) < 2:
            return None
        random.shuffle(uniq)
        out["options"] = uniq
        out["answer"] = uniq.index(correct)
    if t == "choice":
        out["question"] = s("question")
        out["explain"] = s("explain")
    elif t == "fill":
        out["sentence"] = jf(re.sub(r"[_＿]{2,}|…{2,}|\.{4,}", "___", s("sentence")))
        if out["sentence"].count("___") != 1:
            return None
        out["ko"] = s("ko")
        out["explain"] = s("explain")
        filled = out["sentence"].replace("___", out["options"][out["answer"]], 1)
        out["reading"] = ja_reading(out["sentence"]) if lang == "ja" else ""  # keeps ___
    elif t == "listen":
        out["audio"] = jf(s("audio"))
        if not out["audio"] or len(out["audio"]) > 140:
            return None
        out["explain"] = s("explain")
        out["reading"] = ja_reading(out["audio"]) if lang == "ja" else ""
    elif t == "build":
        ans = [jf(x.strip()) for x in e["answer"]]
        if not all(ans):   # a token that was only Chinese-only characters is gone: no sentence left to build
            return None
        extra = [jf(x.strip()) for x in (e.get("extra") or []) if isinstance(x, str) and x.strip()]
        extra = [x for x in extra if x and x not in ans][:2]
        out["ko"] = s("ko")
        out["answer"] = ans
        out["extra"] = extra
        out["explain"] = s("explain")
        out["reading"] = ja_reading("".join(ans)) if lang == "ja" else ""
    elif t == "speak":
        out["text"] = jf(s("text"))
        if not out["text"] or len(out["text"]) > 140:
            return None
        out["ko"] = s("ko")
        out["reading"] = ja_reading(out["text"]) if lang == "ja" else ""
    return out


LESSON_PASS_CRITERIA = (
    "PASS CRITERIA (every exercise must satisfy all):\n"
    "(a) exactly one option is correct; every other option is clearly wrong.\n"
    "(b) the correct option inserted into the blank gives a natural, grammatical sentence.\n"
    "(c) every target-language field is in the target language, never Korean.\n"
    "(d) build tokens join into one complete sentence of at least 3 tokens, and the extra tokens cannot also form a valid sentence with them.\n"
    "(e) the Korean translation matches the sentence meaning.\n"
    "(f) no sentence repeats within the lesson.\n"
    "FORBIDDEN: options that are synonyms of the answer; option prefixes such as \"A.\", \"B.\" or \"1)\"; explanations in English "
    "(\"explain\" is always Korean).\n\n"
)


def lesson_sentence_key(f, lang):
    """the target-language sentence an exercise is built on, normalised (None for choice questions)"""
    t = f["type"]
    if t == "fill":
        s = f["sentence"].replace("___", f["options"][f["answer"]], 1)
    elif t == "build":
        s = ("" if lang == "ja" else " ").join(f["answer"])
    elif t == "listen":
        s = f["audio"]
    elif t == "speak":
        s = f["text"]
    else:
        return None
    s = re.sub(r"[\W_]+", "", s.lower(), flags=re.UNICODE)
    return ("sent", s) if s else None


def run_lesson(req):
    lang = need_lang(req.lang)
    n = clamp_int(req.month, 1, 12, 1)
    w = clamp_int(req.week, 1, 4, 1)
    stage = clamp_int(req.stage, 1, 4, stage_of(n))
    ln = LNAME[lang]
    ja_note = (' For Japanese, every exercise that shows a Japanese sentence must also have a "reading" field with the full hiragana reading (hiragana only). '
               'In "build", split the sentence into natural chunks such as 毎朝 / 七時に / 起きます (not single characters).') if lang == "ja" else \
        ' In "build", split the sentence into words. "reading" fields must be empty strings.'
    prompt = (
        "Create a short " + ln + " lesson for a Korean learner, like a Duolingo lesson.\n"
        "Level: " + LEVEL[lang][stage] + "\n" + context_text(lang, n, w) + "\n\n"
        "Make exactly 10 exercises practicing this week's focus, mixing types: 2 \"choice\", 4 \"build\", 2 \"listen\", 2 \"speak\" (no \"fill\"). "
        "Order them from easier to harder and mix the types. All instructions, translations and explanations must be natural Korean. "
        "IMPORTANT: this is a lesson in " + ln + ", so the fill \"sentence\" and its \"options\", the build \"answer\" and \"extra\" tokens, the listen \"audio\" and the speak \"text\" must be written in " + ln + ", never in Korean. Only \"question\", \"ko\", \"explain\", \"title\" and the listen \"options\" are Korean. "
        "Sentences must be natural things a native speaker really says; never repeat the same sentence in two exercises. Every sentence must be grammatical and complete (never glue extra words such as です onto a greeting). \"build\": the answer tokens joined together must form ONE natural sentence of at least 3 tokens. \"fill\": putting the correct option into the blank must give a natural correct sentence, and the other 3 options must be clearly wrong. \"listen\"/\"speak\": a single short sentence (under 12 words). If the topic is about writing systems or pronunciation, still use simple real words and phrases that practice it. For \"build\", \"extra\" are 2 plausible wrong tokens that are NOT in \"answer\". For choice/fill/listen, \"options\" has 4 distinct options and \"answer\" is the 0-based index of the correct one." + ja_note + "\n\n"
        + LESSON_PASS_CRITERIA +
        "Field guide:\n"
        '- choice: {"type":"choice","question":"Korean question about meaning or usage, may quote a target-language phrase","options":[4],"answer":0,"explain":"one Korean sentence"}\n'
        '- fill: {"type":"fill","sentence":"target-language sentence containing ___ for the blank","reading":"","ko":"Korean meaning of the full sentence","options":[4 options for the blank],"answer":0,"explain":"one Korean sentence"}\n'
        '- build: {"type":"build","ko":"Korean sentence to translate","answer":["tokens","of","the","correct","sentence"],"extra":["2 distractor tokens"],"reading":"","explain":"one Korean sentence"}\n'
        '- listen: {"type":"listen","audio":"target-language sentence that will be read aloud","reading":"","options":[4 Korean meanings],"answer":0,"explain":"one Korean sentence"}\n'
        '- speak: {"type":"speak","text":"target-language sentence for the learner to say aloud","reading":"","ko":"Korean meaning"}\n'
        "title: a short Korean lesson title."
    )
    title = ""
    good = []
    for attempt in range(2):
        try:
            data = ollama_json([{"role": "user", "content": prompt}], LESSON_SCHEMA, temperature=0.6 if attempt == 0 else 0.4, num_predict=3200)
        except ApiError as e:
            if attempt == 1 or e.status in (503, 504):
                raise
            log.warning("lesson attempt 1 failed: %s", e.msg)
            continue
        exs = data.get("exercises") if isinstance(data, dict) else []
        cur = []
        seen_keys = set()
        for e in exs or []:
            if valid_ex(e):
                f = finish_ex(e, lang)
                if not f or not target_lang_ok(f, lang):
                    continue
                key = (f["type"], f.get("question") or f.get("sentence") or f.get("audio") or f.get("text") or "".join(f.get("answer") if f["type"] == "build" else []))
                sent_key = lesson_sentence_key(f, lang)  # (f) the same sentence never comes twice, whatever the type
                if key in seen_keys or (sent_key and sent_key in seen_keys):
                    continue
                seen_keys.add(key)
                if sent_key:
                    seen_keys.add(sent_key)
                cur.append(f)
        log.info("lesson attempt %d: %d/%d valid", attempt + 1, len(cur), len(exs or []))
        if len(cur) > len(good):
            good = cur
            title = str(data.get("title", "") or "").strip()
        if len(good) >= 4:
            break
    if len(good) < 4:
        raise ApiError("레슨을 만들지 못했어요. 잠시 뒤에 다시 시도해 주세요.", 502)
    try:
        good = verify_answers(lang, builds_to_fills(good[:10], lang))
    except LessonUnchecked as e:
        return lesson_fallback(req, str(e))
    return {"title": title or "오늘의 레슨", "exercises": good, "source": "ai"}


KANA = re.compile(r"[ぁ-んァ-ヶ]")
LATIN = re.compile(r"[A-Za-z]")


def target_lang_ok(e, lang):
    """The fields the learner reads or says must really be in the target language (the 8B model sometimes
    writes a whole 'English' lesson in Korean)."""
    t = e["type"]
    texts = []
    if t == "fill":
        texts = [e["sentence"]] + e["options"]
    elif t == "build":
        texts = ["".join(e["answer"])]
    elif t == "listen":
        texts = [e["audio"]]
    elif t == "speak":
        texts = [e["text"]]
    elif t == "choice":
        return True  # the question is Korean and its options may be in either language
    for s in texts:
        if HANGUL.search(s):
            return False
    joined = " ".join(texts)
    if lang == "en":
        return LATIN.search(joined) is not None
    return KANA.search(joined) is not None or HAN.search(joined) is not None


EN_FUNCTION_WORDS = set("a an the to of in on at for and or but is am are was were be do does did i you he she it we they my your his her our their this that".split())


def builds_to_fills(exs, lang):
    """Turn every second "build" item into a fill-in-the-blank built from the same natural sentence.
    Written-from-scratch blanks from the 8B model were often ambiguous; blanking one word of a sentence
    the model already wrote well, with the build's own distractor tokens as wrong options, is safer."""
    builds = [e for e in exs if e["type"] == "build"]
    pool = [t for b in builds for t in b["answer"]]
    out, k = [], 0
    for e in exs:
        if e["type"] != "build":
            out.append(e)
            continue
        k += 1
        f = fill_from_build(e, lang, pool) if k % 2 == 0 else None
        out.append(f or e)
    return out


def fill_from_build(b, lang, pool):
    toks = b["answer"]
    def content(i):
        t = toks[i]
        core = re.sub(r"[^\w]", "", t)
        if lang == "en":
            return len(core) >= 3 and core.lower() not in EN_FUNCTION_WORDS
        return len(core) >= 2
    cands = [i for i in range(len(toks)) if content(i)]
    if not cands:
        return None
    i = random.choice(cands)
    correct = toks[i]
    wrong = [x for x in b.get("extra", []) if x != correct]
    for t in random.sample(pool, len(pool)):
        if len(wrong) >= 3:
            break
        if t != correct and t not in wrong and t not in toks:
            wrong.append(t)
    if len(wrong) < 2:
        return None
    opts = [correct] + wrong[:3]
    random.shuffle(opts)
    blanked = toks[:i] + ["___"] + toks[i + 1:]
    sentence = (" ".join(blanked) if lang == "en" else "".join(blanked))
    return {"type": "fill", "sentence": sentence, "ko": b.get("ko", ""), "options": opts, "answer": opts.index(correct),
            "explain": b.get("explain", ""), "reading": ja_reading(sentence) if lang == "ja" else ""}


class LessonUnchecked(Exception):
    """the answer checker failed, skipped items or left fewer than 4 good items: the AI lesson must not be shown unchecked"""


def lesson_fallback(req, reason):
    """Rule-based Tatoeba lesson for the same request (used when the AI lesson could not be verified)."""
    import sqlite3
    log.warning("AI lesson not verified (%s); falling back to a rule-based Tatoeba lesson", reason)
    if readmode.tatoeba_ready():
        try:
            n = clamp_int(req.month, 1, 12, 1)
            d = lesson_rules.make_lesson(need_lang(req.lang), n, clamp_int(req.week, 1, 4, 1), clamp_int(req.stage, 1, 4, stage_of(n)))
            d["source"] = "tatoeba"
            d["fallback_reason"] = reason
            return d
        except (sqlite3.Error, ApiError) as e:
            log.warning("Tatoeba fallback lesson failed: %s", getattr(e, "msg", e))
    raise ApiError("레슨을 확인하지 못했어요. 잠시 뒤에 다시 시도해 주세요.", 503)


OX = {"type": "string", "enum": ["O", "X"]}
VERIFY_SCHEMA = S(answers={"type": "array", "items": S(id={"type": "integer"}, answer={"type": "integer"},
                                                       a=OX, b=OX, c=OX, d=OX, e=OX)})
VERIFY_CRITERIA = ("a", "b", "c", "d", "e")


def verify_answers(lang, exs):
    """Second pass with explicit pass criteria: the checker solves every multiple-choice item blind and marks
    each criterion (a)-(e) of LESSON_PASS_CRITERIA O or X. An item is dropped if its answer key disagrees with
    the checker's answer or any criterion is X. (Solving one item is much more reliable for the 8B model than
    writing a lesson.)"""
    items = []
    for i, e in enumerate(exs):
        if e["type"] == "choice":
            items.append({"id": i, "kind": "question", "question": e["question"], "options": e["options"]})
        elif e["type"] == "fill":
            items.append({"id": i, "kind": "fill the blank (___)", "sentence": e["sentence"], "korean_meaning": e.get("ko", ""), "options": e["options"]})
        elif e["type"] == "listen":
            items.append({"id": i, "kind": "pick the correct Korean meaning", "sentence": e["audio"], "options": e["options"]})
        elif e["type"] == "build":
            items.append({"id": i, "kind": "build the sentence from tokens", "tokens": e["answer"], "extra_tokens": e.get("extra", []),
                          "korean_meaning": e.get("ko", "")})
        elif e["type"] == "speak":
            items.append({"id": i, "kind": "say the sentence aloud", "sentence": e["text"], "korean_meaning": e.get("ko", "")})
    if not items:
        return exs
    prompt = ("You are checking quiz items for a Korean learner of " + LNAME[lang] + ". For multiple-choice items "
              "(those with \"options\") solve the item yourself and give the 0-based index of the single correct option "
              "as \"answer\"; for other items set \"answer\" to -1. Think about grammar and meaning carefully.\n"
              "Then mark each criterion \"O\" (satisfied, or not applicable to this kind of item) or \"X\" (violated):\n"
              "(a) exactly one option is correct; the others are clearly wrong and none is a synonym of the answer.\n"
              "(b) the sentence (with the correct option inserted into the blank, if any) is natural, grammatical " + LNAME[lang] + ".\n"
              "(c) every " + LNAME[lang] + " field (sentence, tokens, " + LNAME[lang] + " options) is really " + LNAME[lang] + ", not Korean.\n"
              "(d) build: the tokens joined in order form one complete sentence of at least 3 tokens, and the extra tokens "
              "cannot also be used to form a valid sentence with the same meaning.\n"
              "(e) the Korean meaning / Korean option marked correct matches the sentence meaning.\n\n"
              + json.dumps(items, ensure_ascii=False) +
              '\n\nReply with JSON: {"answers": [{"id": <item id>, "answer": <index or -1>, "a": "O", "b": "O", "c": "O", "d": "O", "e": "O"}, ...]} covering every item.')
    try:
        data = ollama_json([{"role": "user", "content": prompt}], VERIFY_SCHEMA, temperature=0.0, num_predict=4000, think=True,
                           cache_key_kind="verify")
    except Exception as e:
        log.warning("answer check failed: %s", getattr(e, "msg", e))
        raise LessonUnchecked("answer_check_failed")
    got = {}
    for a in (data.get("answers") or []) if isinstance(data, dict) else []:
        if isinstance(a, dict) and isinstance(a.get("id"), int) and isinstance(a.get("answer"), int):
            got[a["id"]] = (a["answer"], [c for c in VERIFY_CRITERIA if str(a.get(c, "O")).upper() == "X"])
    missing = [i for i in range(len(exs)) if i not in got]
    if missing:
        log.warning("answer check skipped %d of %d items", len(missing), len(exs))
        raise LessonUnchecked("answer_check_incomplete")
    keep = []
    for i, e in enumerate(exs):
        if i in got:
            ans, bad = got[i]
            if e["type"] in ("choice", "fill", "listen") and ans != e["answer"]:
                log.info("dropping exercise %d (%s): key %s, checker %s", i, e["type"], e["answer"], ans)
                continue
            if bad:
                log.info("dropping exercise %d (%s): criteria %s marked X", i, e["type"], ",".join(bad))
                continue
        keep.append(e)
    if len(keep) < 4:
        raise LessonUnchecked("too_few_verified_items")
    return keep


# ----------------------------------------------------------------------------------------------
# API
# ----------------------------------------------------------------------------------------------
class TtsReq(BaseModel):
    text: str = ""
    lang: str = "en"
    speed: Optional[float] = 1.0
    voice: Optional[str] = ""   # Kokoro voice id (see GET /tts/voices); empty/unknown -> the default voice


class SttReq(BaseModel):
    lang: str = "en"
    audio_b64: str = ""


class ScoreReq(BaseModel):
    lang: str = "en"
    target: str = ""
    reading: Optional[str] = ""
    audio_b64: str = ""


import features
from concurrent.futures import ThreadPoolExecutor

features.init(log=log, ApiError=ApiError, synth_wav=synth_wav, ojt=ojt, ja_to_kata=ja_to_kata,
              split_mora=split_mora, patch_espeak=_patch_espeak_for_nonascii_path, en_words=en_words)
_ph_pool = ThreadPoolExecutor(max_workers=2, thread_name_prefix="ph")
grammar.init(log=log)
llm_opencode.init(log=log)

import reading as readmode  # reading mode (/reading/*) + Tatoeba examples (/examples)

readmode.init(log=log, ApiError=ApiError, ollama_json=ollama_json, ko_ok=ko_ok, ja_reading=ja_reading,
             patch_espeak=_patch_espeak_for_nonascii_path)


import lesson_rules  # rule-based lessons from Tatoeba sentences (POST /lesson, source "tatoeba")

lesson_rules.init(log=log, ApiError=ApiError, ja_reading=ja_reading, curriculum=get_curriculum, plain=plain)


class ReadingAnalyzeReq(BaseModel):
    lang: str
    text: Optional[str] = ""


class ReadingGlossReq(BaseModel):
    lang: str
    items: List[Any] = []


class ProsodyReq(BaseModel):
    lang: str = "en"
    text: str = ""
    reading: Optional[str] = ""
    audio_b64: Optional[str] = ""


class Turn(BaseModel):
    role: str = "me"
    text: str = ""


class ChatReq(BaseModel):
    lang: str = "en"
    stage: Optional[int] = None
    month: Optional[int] = 1
    week: Optional[int] = 1
    scenario: Optional[dict] = None
    history: List[Turn] = []
    skip_fix: Optional[bool] = False
    conv_id: Optional[str] = ""  # lets the OpenCode engine keep one session per conversation (only the new message is sent)
    tts_speed: Optional[float] = 1.0     # the user's current TTS speed/voice: the server starts synthesizing the reply right away
    tts_voice: Optional[str] = ""
    presynth: Optional[bool] = True      # false when the app's auto-speak is off


class FixReq(BaseModel):
    lang: str = "en"
    stage: Optional[int] = 1
    text: str = ""
    prev_ai: Optional[str] = ""


class FeedbackReq(BaseModel):
    lang: str = "en"
    stage: Optional[int] = 1
    history: List[Turn] = []


class LessonReq(BaseModel):
    lang: str = "en"
    month: Optional[int] = 1
    week: Optional[int] = 1
    stage: Optional[int] = None
    source: Optional[str] = None  # "tatoeba" (default, rule-based) | "ai" (LLM)


def ensure_ollama():
    """Start the Ollama tray app if its API is not answering (it normally starts at Windows login)."""
    try:
        requests.get(CFG["ollama_url"] + "/api/tags", timeout=1.5)
        return
    except Exception:
        pass
    if ("ollama_url",) in _OVERRIDES:   # --ollama-url points at another (test) server: never start the real Ollama app for it
        log.info("ollama_url forced by --ollama-url: not starting the Ollama app")
        return
    exe = os.path.join(os.environ.get("LOCALAPPDATA", ""), "Programs", "Ollama", "ollama app.exe")
    if not os.path.exists(exe):
        log.warning("Ollama is not running and %s was not found", exe)
        return
    log.info("starting Ollama: %s", exe)
    try:
        subprocess.Popen([exe], close_fds=True, creationflags=0x00000008 | 0x00000200)  # DETACHED_PROCESS | NEW_PROCESS_GROUP
    except Exception:
        log.exception("could not start Ollama")
        return
    for _ in range(30):
        time.sleep(1)
        try:
            requests.get(CFG["ollama_url"] + "/api/tags", timeout=1.5)
            log.info("Ollama is up")
            return
        except Exception:
            pass
    log.warning("Ollama did not come up within 30 s")


def _warmup():
    time.sleep(0.5)
    grammar.prestart()  # LanguageTool JVM starts in its own thread (about 2-10 s) so the first /fix is quick
    if llm_provider() == "opencode":
        llm_opencode.prestart()  # `opencode serve` (about 2 s)
    steps = [("stt", get_stt), ("tts-en", lambda: get_tts("en")), ("tts-ja", lambda: get_tts("ja")), ("ojt", ojt),
             ("phoneme", features.phoneme_load), ("pitch", features.warmup_pitch), ("reading", readmode.warmup), ("lesson-pool", lesson_rules.warmup)]
    for name, fn in steps:
        try:
            fn()
        except Exception:
            log.exception("warmup %s failed", name)
    if using_remote():
        log.info("LLM provider %s (%s)", llm_provider(), "found" if llm_available() else "NOT installed")
        log.info("warmup finished")
        return
    ensure_ollama()
    try:  # load the LLM into memory so the first chat is quick
        ollama_json([{"role": "user", "content": "Reply with JSON: say hello."}], CHAT_SCHEMA, temperature=0.1, num_predict=250)
    except Exception:
        log.warning("LLM warmup failed (is Ollama running?)", exc_info=True)
    log.info("warmup finished")


from contextlib import asynccontextmanager


@asynccontextmanager
async def lifespan(app_):
    log.info("server starting; config=%s", json.dumps(CFG))
    try:
        cache_evict()   # TTS clip cache stays under its cap (LRU)
    except Exception:
        log.exception("tts cache eviction at start failed")
    threading.Thread(target=_warmup, daemon=True).start()
    lan.start_if_enabled()   # phone link: second listener (0.0.0.0:<lan.port>) only when the saved config says it is on
    yield
    lan.shutdown()


app = FastAPI(title="Speaking practice backend", lifespan=lifespan)
# --lan-bind / --devices-file are for test servers; a test server (--port) never starts the link from config.json and never saves it
lan.attach(app, CFG, save_config, log, BASE, tag=ARG_TAG, devices_file=_arg("--devices-file"), bind=_arg("--lan-bind", "0.0.0.0"),
           persist=not ARG_PORT, auto_start=not ARG_PORT)


@app.exception_handler(ApiError)
async def _api_error(request: Request, exc: ApiError):
    return JSONResponse({"error": exc.msg}, status_code=exc.status)


@app.exception_handler(RequestValidationError)
async def _validation_error(request: Request, exc: RequestValidationError):
    return JSONResponse({"error": "요청 형식이 올바르지 않아요."}, status_code=422)


@app.exception_handler(StarletteHTTPException)
async def _http_error(request: Request, exc: StarletteHTTPException):
    msg = "찾을 수 없는 주소예요." if exc.status_code == 404 else "요청을 처리할 수 없어요."
    return JSONResponse({"error": msg}, status_code=exc.status_code)


@app.exception_handler(Exception)
async def _any_error(request: Request, exc: Exception):
    log.exception("unhandled error on %s", request.url.path)
    return JSONResponse({"error": "서버에서 예기치 않은 오류가 났어요. 잠시 뒤에 다시 시도해 주세요."}, status_code=500)


@app.middleware("http")
async def _timing(request: Request, call_next):
    t0 = time.time()
    resp = await call_next(request)
    log.info("%s %s -> %s %.2fs", request.method, request.url.path, resp.status_code, time.time() - t0)
    return resp


class LlmReq(BaseModel):
    provider: str = "ollama"
    # openai_api only (all optional): preset id, model id, "opencode" | "secret", and a key to store in secrets.json
    preset: Optional[str] = None
    model: Optional[str] = None
    key_source: Optional[str] = None
    api_key: Optional[str] = None


def _api_info():
    s = llm_api.settings(CFG)
    return {"preset": s["preset"], "model": s["model"], "key_source": s["key_source"], "base_url": s["base_url"],
            "has_key": llm_api.has_key(s), "note": s["note"],
            "presets": [{"id": k, "label": v["label"], "base_url": v["base_url"], "default_model": v["model"], "note": v["note"]}
                        for k, v in llm_api.PRESETS.items()]}


@app.get("/llm")
def llm_get():
    api = _api_info()
    return {"provider": llm_provider(),
            # the app's picker: the free DeepSeek through OpenCode (default) and the offline local model.
            # "openai_api" (any OpenAI-compatible API + key) stays selectable through POST /llm; its settings are below.
            "options": [{"id": "opencode", "label": llm_opencode.LABEL, "available": llm_opencode.available()},
                        {"id": "ollama", "label": "오프라인 로컬 (%s)" % CFG["llm_model"], "available": _ollama_installed()}],
            "openai_api": dict(api, label="API 키 (%s · %s)" % (llm_api.PRESETS[api["preset"]]["label"], api["model"])),
            "llm_fallback": _fallback_status()}


@app.get("/llm/models")
def llm_models(preset: str = "", key_source: str = ""):
    """Model ids of an OpenAI-compatible provider ({base}/models with the key); "free" marks ids containing 'free'."""
    try:
        s, models = llm_api.list_models(CFG, preset or None, key_source or None)
    except llm_common.LlmError as e:
        raise ApiError(e.msg, e.status)
    return {"preset": s["preset"], "models": models, "note": s["note"]}


@app.post("/llm")
def llm_set(req: LlmReq):
    p = req.provider if req.provider in ENGINES else None
    if not p:
        raise ApiError("알 수 없는 AI 엔진이에요.", 400)
    if p == "openai_api":
        api = dict(CFG.get("openai_api") or {})
        if req.preset is not None:
            if req.preset not in llm_api.PRESETS:
                raise ApiError("알 수 없는 API 제공자예요.", 400)
            if req.preset != api.get("preset"):
                api.pop("model", None)
                api.pop("base_url", None)
            api["preset"] = req.preset
        if req.model is not None:
            api["model"] = req.model.strip()[:200]
        if req.key_source is not None:
            if req.key_source not in llm_api.KEY_SOURCES:
                raise ApiError("키 가져오는 방법이 올바르지 않아요.", 400)
            api["key_source"] = req.key_source
        CFG["openai_api"] = api
        if req.api_key is not None:  # stored in backend/secrets.json only, never in config.json or a response
            llm_api.save_secret(llm_api.settings(CFG)["preset"], req.api_key)
            if req.api_key.strip():
                CFG["openai_api"]["key_source"] = "secret"
    CFG["llm_provider"] = p
    _llm_health.update(t=0.0, ok=False)
    llm_fallback.clear()  # choosing an engine again means: try it again now
    if not ARG_PORT:  # a side-by-side test server must not change the app's config
        save_config(CFG)
    if p == "ollama":
        threading.Thread(target=ensure_ollama, daemon=True).start()
    if p == "opencode":
        llm_opencode.prestart()
    return llm_get()


@app.post("/llm/test")
def llm_test():
    t0 = time.time()
    msgs = [{"role": "user", "content": 'Reply with JSON {"fix": "OK", "fix_ko": "확인"}.'}]
    if using_remote():  # test the selected engine itself, never the local fallback
        try:
            d = _remote_json(msgs, FIX_SCHEMA, 0.0, 60)
        except llm_common.LlmError as e:
            raise ApiError(e.msg, e.status)
        llm_fallback.clear()  # it answers again
    else:
        d = ollama_json(msgs, FIX_SCHEMA, temperature=0.0, num_predict=60)
    return {"ok": True, "provider": llm_provider(), "seconds": round(time.time() - t0, 1), "reply": d}


class LimitSimReq(BaseModel):
    message: str = ""   # "" turns the simulation off
    clear: Optional[bool] = False


if os.environ.get("HOEHWA_TEST_HOOKS") == "1":
    @app.post("/debug/engine_limit")
    def debug_engine_limit(req: LimitSimReq):
        """Test only (HOEHWA_TEST_HOOKS=1): make every remote engine call fail as if it answered `message`."""
        llm_common.SIMULATE_LIMIT = req.message or ""
        if req.clear:
            llm_fallback.clear()
        return {"ok": True, "simulating": bool(llm_common.SIMULATE_LIMIT), "llm_fallback": _fallback_status()}

    @app.post("/debug/config")
    def debug_config(req: dict):
        """Test only: change in-memory settings (never saved), e.g. {"grammar_llm_polish": false}."""
        for k in ("grammar_llm_polish",):
            if k in req:
                CFG[k] = bool(req[k])
        if isinstance(req.get("openai_api"), dict):  # e.g. point the API engine at a mock server (base_url)
            CFG.setdefault("openai_api", {}).update({k: v for k, v in req["openai_api"].items()
                                                     if k in ("preset", "base_url", "model", "key_source")})
        if "llm_provider" in req and req["llm_provider"] in ENGINES:
            CFG["llm_provider"] = req["llm_provider"]
            llm_fallback.clear()
        return {"ok": True, "grammar_llm_polish": CFG.get("grammar_llm_polish", True), "cache": llm_cache.stats(),
                "grammar": grammar.status()}


def _ollama_installed():
    return os.path.exists(os.path.join(os.environ.get("LOCALAPPDATA", ""), "Programs", "Ollama", "ollama.exe"))


@app.get("/health")
def health():
    return {"ok": True, "stt": _stt_model is not None, "tts": {"en": _tts_ready["en"], "ja": _tts_ready["ja"]}, "tts_device": _tts_device,
            "llm": llm_available(), "llm_model": CFG["llm_model"], "llm_provider": llm_provider(), "score": _stt_model is not None and _ojt is not None,
            "phoneme": features.phoneme_ready(), "tatoeba": readmode.tatoeba_ready(),
            "grammar": grammar.installed(), "llm_fallback": _fallback_status()}


def _fallback_status():
    if not using_remote():
        return {"active": False, "until": None, "reason": ""}
    if llm_provider() == "opencode" and not llm_opencode.available():
        if local_llm_reachable():
            return {"active": True, "until": None,
                    "reason": "OpenCode가 설치되어 있지 않아서 무료 DeepSeek 대신 로컬 AI로 답해요. (npm install -g opencode-ai)"}
        return {"active": True, "until": None,
                "reason": "AI 엔진을 쓸 수 없어요: OpenCode가 설치되어 있지 않고 로컬 AI(Ollama)도 연결되지 않아요. "
                          "문법 검사기만 쓸 수 있어요. (npm install -g opencode-ai)"}
    st = llm_fallback.status(llm_provider())
    if st["active"] and not local_llm_reachable():   # the remote engine is blocked and the local model cannot stand in
        st = llm_fallback.status(llm_provider(), local_ok=False)
    return st


@app.get("/curriculum")
def curriculum():
    return get_curriculum()


@app.post("/tts")
def tts(req: TtsReq):
    need_lang(req.lang)
    data = synth_wav(req.text, req.lang, req.speed if req.speed is not None else 1.0, req.voice)
    return Response(content=data, media_type="audio/wav")


@app.get("/tts/voices")
def tts_voices():
    return voices_info()


@app.post("/stt")
def stt(req: SttReq):
    need_lang(req.lang)
    audio = decode_audio_b64(req.audio_b64)
    text, words, dur = transcribe(audio, req.lang)
    return {"text": text, "words": words, "duration": dur}


@app.post("/score")
def score(req: ScoreReq):
    need_lang(req.lang)
    if not (req.target or "").strip():
        raise ApiError("연습할 문장이 비어 있어요.", 400)
    audio = decode_audio_b64(req.audio_b64)
    # the phoneme recognizer (CPU, torch) runs beside Whisper so /score stays fast
    ph_fut = None
    if req.lang == "en" and features.phoneme_ready() and len(audio) >= 3200 and float(np.max(np.abs(audio))) >= 0.003:
        ph_fut = _ph_pool.submit(features.phoneme_probs, audio)
    text, words, _dur = transcribe(audio, req.lang)
    if req.lang == "en":
        res = score_en(req.target, words, text)
    else:
        res = score_ja(req.target, req.reading or "", words, text)
    if ph_fut is not None:
        t0 = time.time()
        try:
            ph_fut.result()
            add_phonemes(res, req, audio)
        except Exception:
            log.exception("phoneme analysis failed")
        log.info("phoneme analysis +%.2fs", time.time() - t0)
    return res


def add_phonemes(res, req, audio):
    """adds units[i].ph and up to 2 phoneme tips to a /score result (in place)"""
    if res.get("score", 0) == 0 and res.get("transcript", "") == "":
        return
    if req.lang != "en":
        return  # Japanese phoneme feedback is built (features.JA_ENABLED) but switched off for now
    if req.lang == "en":
        words = [u["t"] for u in res["units"]]
        ph, tips = features.attach_phonemes("en", None, None, audio, words=words)
    else:
        src = (req.reading or "").strip() or req.target
        moras = split_mora(ja_to_kata(src))
        if len(moras) != len(res["units"]):
            return
        ph, tips = features.attach_phonemes("ja", None, None, audio, moras=moras)
    if ph is None:
        return
    for u, p in zip(res["units"], ph):
        u["ph"] = p
    if tips:
        covered = {w for _t, w in tips}
        base = [t for t in res["tips_ko"] if t != NO_VOICE_TIP]
        lead = [t for t in base if t.startswith("목표 문장과 많이 다르게")]
        # a generic word-level tip about a word the phoneme tips already explain is dropped
        rest = [t for t in base if t not in lead and not any((("'%s'" % w) in t or t.startswith(w)) for w in covered)]
        res["tips_ko"] = (lead + [t for t, _w in tips] + rest)[:3]


@app.post("/prosody")
def prosody(req: ProsodyReq):
    lang = need_lang(req.lang)
    text = (req.text or "").strip()
    if not text:
        raise ApiError("연습할 문장이 비어 있어요.", 400)
    audio = decode_audio_b64(req.audio_b64) if (req.audio_b64 or "").strip() else None
    t0 = time.time()
    out = features.prosody(lang, text[:300], req.reading or "", audio)
    log.info("prosody %s audio=%s %.2fs", lang, audio is not None, time.time() - t0)
    return out


@app.post("/chat")
def chat(req: ChatReq):
    out = run_chat(req)
    # wrap: while the reply travels to the app, synthesize its chunks (first one first) into the TTS cache
    try:
        if isinstance(out, dict) and str(out.get("reply", "")).strip():
            lang = need_lang(req.lang)
            reply = str(out["reply"]).strip()
            if req.presynth is not False:
                chunks = presynth_reply(reply, lang, req.tts_speed if req.tts_speed is not None else 1.0, req.tts_voice)
            else:
                chunks = tts_chunks(reply, lang)
            out = dict(out)
            out["tts_chunks"] = chunks
    except Exception:
        log.warning("chat presynth wrapper failed", exc_info=True)
    return out


# ---- microphone ----------------------------------------------------------------------------
# Recording happens here (PortAudio via sounddevice) instead of in Godot: Godot's WASAPI input
# crashed the app with some USB audio interfaces (ZOOM H/F series) when the mic was opened and
# closed for every recording. A failure here only fails one request; it never takes the UI down.
class MicRecorder:
    MAX_SECONDS = 35.0

    def __init__(self):
        self.lock = threading.Lock()
        self.stream = None
        self.chunks = []
        self.sr = 16000
        self.peak = 0.0
        self.level = 0.0
        self.t0 = 0.0

    @staticmethod
    def _sd():
        import sounddevice as sd
        return sd

    def devices(self):
        sd = self._sd()
        apis = sd.query_hostapis()
        default_api = sd.default.hostapi if isinstance(sd.default.hostapi, int) else 0
        mme = next((i for i, a in enumerate(apis) if a["name"] == "MME"), default_api)
        out = []
        for i, d in enumerate(sd.query_devices()):
            if d["max_input_channels"] > 0 and d["hostapi"] == mme and "매퍼" not in d["name"] and "Mapper" not in d["name"]:
                out.append(d["name"])
        try:
            default_name = sd.query_devices(None, "input")["name"]
        except Exception:
            default_name = ""
        return out, default_name

    def _find(self, name):
        if not name or name == "Default":
            return None
        sd = self._sd()
        for i, d in enumerate(sd.query_devices()):
            if d["max_input_channels"] > 0 and d["name"] == name and sd.query_hostapis(d["hostapi"])["name"] == "MME":
                return i
        return None

    def _callback(self, indata, frames, time_info, status):
        mono = indata.mean(axis=1) if indata.ndim > 1 else indata[:, 0]
        self.chunks.append(mono.copy())
        p = float(np.abs(mono).max()) if mono.size else 0.0
        self.peak = max(self.peak, p)
        self.level = max(min(p * 2.5, 1.0), self.level * 0.85)
        if time.time() - self.t0 > self.MAX_SECONDS:
            raise self._sd().CallbackStop()

    def start(self, device_name):
        sd = self._sd()
        with self.lock:
            self._close()
            dev = self._find(device_name)
            info = sd.query_devices(dev, "input")
            self.sr = int(info["default_samplerate"]) or 44100
            ch = 1 if info["max_input_channels"] < 2 else 2
            self.chunks, self.peak, self.level, self.t0 = [], 0.0, 0.0, time.time()
            try:
                self.stream = sd.InputStream(device=dev, channels=ch, samplerate=self.sr, dtype="float32", callback=self._callback)
                self.stream.start()
            except Exception as e:
                self.stream = None
                log.warning("mic start failed: %s", e)
                raise ApiError("마이크를 열지 못했어요. 설정에서 다른 마이크를 고르거나, 윈도우 마이크 권한을 확인해 주세요.", 500)

    def _close(self):
        if self.stream is not None:
            try:
                self.stream.stop()
                self.stream.close()
            except Exception:
                log.warning("mic close failed", exc_info=True)
            self.stream = None

    def stop(self):
        with self.lock:
            was = self.stream is not None
            self._close()
            chunks, self.chunks = self.chunks, []
        if not was or not chunks:
            return None, 0.0
        audio = np.concatenate(chunks).astype(np.float32)
        return audio, self.peak

    def status(self):
        rec = self.stream is not None and self.stream.active
        return {"recording": bool(rec), "level": round(self.level, 3), "elapsed": round(time.time() - self.t0, 2) if rec else 0.0}


MIC = MicRecorder()


def wav16k_b64(audio, sr):
    import base64
    from scipy.signal import resample_poly
    g = math.gcd(int(sr), 16000)
    y = resample_poly(audio, 16000 // g, int(sr) // g) if sr != 16000 else audio
    y = np.clip(y, -1.0, 1.0)
    buf = BytesIO()
    import soundfile as sf
    sf.write(buf, (y * 32767).astype(np.int16), 16000, format="WAV", subtype="PCM_16")
    return base64.b64encode(buf.getvalue()).decode("ascii"), len(y) / 16000.0


class MicStartReq(BaseModel):
    device: Optional[str] = ""


@app.get("/mic/devices")
def mic_devices():
    try:
        names, default_name = MIC.devices()
    except Exception:
        log.exception("mic device list failed")
        raise ApiError("마이크 목록을 읽지 못했어요.", 500)
    return {"devices": names, "default": default_name}


@app.post("/mic/start")
def mic_start(req: MicStartReq):
    MIC.start(req.device or "")
    return {"ok": True}


@app.get("/mic/level")
def mic_level():
    return MIC.status()


@app.post("/mic/stop")
def mic_stop():
    audio, peak = MIC.stop()
    if audio is None or audio.size == 0:
        return {"ok": False, "b64": "", "duration": 0.0, "silent": True}
    b64, dur = wav16k_b64(audio, MIC.sr)
    return {"ok": True, "b64": b64, "duration": round(dur, 2), "silent": peak < 0.003}


@app.post("/mic/cancel")
def mic_cancel():
    MIC.stop()
    return {"ok": True}


@app.post("/fix")
def fix(req: FixReq):
    lang = need_lang(req.lang)
    text = (req.text or "").strip()
    if not text:
        raise ApiError("고칠 문장이 비어 있어요.", 400)
    f, fk = correct_learner(lang, clamp_int(req.stage, 1, 4, 1), text[:500], (req.prev_ai or "")[:300])
    return {"fix": f, "fix_ko": fk}


@app.post("/feedback")
def feedback(req: FeedbackReq):
    return run_feedback(req)


@app.post("/lesson")
def lesson(req: LessonReq):
    src = (req.source or "tatoeba").strip().lower()
    if src not in ("tatoeba", "ai"):
        raise ApiError("source는 'tatoeba' 또는 'ai'여야 해요.", 400)
    if src == "tatoeba":
        import sqlite3
        if readmode.tatoeba_ready():
            n = clamp_int(req.month, 1, 12, 1)
            try:
                return lesson_rules.make_lesson(need_lang(req.lang), n, clamp_int(req.week, 1, 4, 1), clamp_int(req.stage, 1, 4, stage_of(n)))
            except sqlite3.Error:
                log.warning("tatoeba DB unreadable; /lesson falls back to the AI lesson")
        else:
            log.warning("tatoeba DB missing or invalid; /lesson falls back to the AI lesson")
    return run_lesson(req)


@app.post("/reading/analyze")
def reading_analyze(req: ReadingAnalyzeReq):
    return readmode.analyze(need_lang(req.lang), req.text)


@app.post("/reading/gloss")
def reading_gloss(req: ReadingGlossReq):
    return readmode.gloss(need_lang(req.lang), req.items)


@app.get("/examples")
def examples(lang: str = "en", q: str = "", limit: int = 5):
    return readmode.examples(need_lang(lang), q, limit)


# ----------------------------------------------------------------------------------------------
def prefetch_wordnet():
    """prefetch stage: WordNet (+ omw-1.4) for the lesson distractor check, whether or not Tatoeba is ready.
    A failure is only reported (the lessons keep working, the wrong-option check is just less exact); returns True/False."""
    print("[prefetch] WordNet (nltk wordnet + omw-1.4) ...", flush=True)
    try:
        ok = bool(lesson_rules.ensure_wordnet_data())
        if ok:  # nltk.download() reports a blocked network by returning False; do not trust "no exception" alone
            ok = all(os.path.exists(os.path.join(lesson_rules.NLTK_DIR, "corpora", pkg + ".zip"))
                     or os.path.isdir(os.path.join(lesson_rules.NLTK_DIR, "corpora", pkg)) for pkg in lesson_rules.NLTK_PKGS)
    except Exception as e:
        log.warning("WordNet prefetch failed: %s", e)
        ok = False
    print("[prefetch] WordNet OK" if ok else "[prefetch] WordNet FAILED (레슨은 계속 동작, 오답 보기 검사 정확도만 낮아짐)", flush=True)
    return ok


def prefetch():
    """setup helper: download/verify every local model and record the working STT device in config.json"""
    print("[prefetch] Whisper ...", flush=True)
    get_stt()
    CFG["stt"]["device"], CFG["stt"]["compute_type"] = _stt_info["device"], _stt_info["compute_type"]
    save_config(CFG)
    print("[prefetch] Whisper OK on %s/%s" % (_stt_info["device"], _stt_info["compute_type"]), flush=True)
    for lang in ("en", "ja"):
        print("[prefetch] Kokoro %s ..." % lang, flush=True)
        try:
            synth_wav("Hello, nice to meet you." if lang == "en" else "はじめまして、よろしくお願いします。", lang, 1.0)
            print("[prefetch] Kokoro %s OK" % lang, flush=True)
        except Exception as e:
            print("[prefetch] Kokoro %s FAILED: %s" % (lang, e), flush=True)
    ojt()
    print("[prefetch] pyopenjtalk OK", flush=True)
    print("[prefetch] phoneme recognizer (wav2vec2-lv-60-espeak-cv-ft, ~1.3 GB) ...", flush=True)
    try:
        features.phoneme_load()
        features.warmup_pitch()
        print("[prefetch] phoneme recognizer OK", flush=True)
    except Exception as e:
        print("[prefetch] phoneme recognizer FAILED: %s" % e, flush=True)
    if readmode.tatoeba_ready():
        print("[prefetch] Tatoeba examples OK (already built)", flush=True)
    else:
        print("[prefetch] Tatoeba examples (download ~30 MB, build ~100 MB) ...", flush=True)
        try:
            code = subprocess.call([sys.executable, "-X", "utf8", os.path.join(BASE, "tatoeba_build.py")], cwd=BASE)
            print("[prefetch] Tatoeba examples %s" % ("OK" if code == 0 and readmode.tatoeba_ready() else "FAILED (exit %s)" % code), flush=True)
        except Exception as e:
            print("[prefetch] Tatoeba examples FAILED: %s" % e, flush=True)
    prefetch_wordnet()
    if readmode.tatoeba_ready():
        try:  # analyse the lesson sentence pool now (about 20 s) instead of at the first app start
            n = len(lesson_rules.pool("en").items) + len(lesson_rules.pool("ja").items)
            print("[prefetch] Tatoeba lesson pool OK (%d sentences)" % n, flush=True)
        except Exception as e:
            print("[prefetch] Tatoeba lesson pool FAILED: %s" % e, flush=True)


def main():
    if PREFETCH:
        prefetch()
        return
    import uvicorn
    uvicorn.run(app, host="127.0.0.1", port=int(CFG["port"]), log_config=None, access_log=False)


if __name__ == "__main__":
    main()
