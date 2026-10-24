# -*- coding: utf-8 -*-
"""Batch English IPA for the phone data pack (build tool helper; no server import).

Same settings as `reading.espeak_ipa` (phonemizer + espeak-ng, en-us, with stress). Words are handed over many lines at a
time (one process start for the whole batch); the number of output lines must equal the number of input lines, else the
batch is redone word by word.
"""
import os
import shutil
import tempfile

_backend = None
_SEP = None


def _ascii(p):
    try:
        p.encode("ascii")
        return True
    except UnicodeEncodeError:
        return False


def _data_signature(d):
    n = total = 0
    for root, _dirs, files in os.walk(d):
        for f in files:
            n += 1
            total += os.path.getsize(os.path.join(root, f))
    return n, total


def _short_path(p):
    if os.name != "nt":
        return None
    try:
        import ctypes
        buf = ctypes.create_unicode_buffer(1024)
        n = ctypes.windll.kernel32.GetShortPathNameW(p, buf, 1024)
        if 0 < n < 1024 and _ascii(buf.value) and os.path.isdir(buf.value):
            return buf.value
    except Exception:
        pass
    return None


def ascii_data_dir(d, work_dir=None):
    """an ASCII-only path to the espeak-ng data folder `d` (espeak cannot open a Korean path on Windows): the 8.3 short
    path, else a copy under an ASCII temp folder (reused when the file count and size match)"""
    if _ascii(d):
        return d
    short = _short_path(d)
    if short:
        return short
    sig = _data_signature(d)
    name = "hoehwa-espeak-ng-data-%d-%d" % sig
    for root in (work_dir, tempfile.gettempdir()):
        if not root or not _ascii(root):
            continue
        dest = os.path.join(root, name)
        try:
            if os.path.isdir(dest) and _data_signature(dest) == sig:
                return dest
            if os.path.isdir(dest):
                shutil.rmtree(dest, ignore_errors=True)
            os.makedirs(root, exist_ok=True)
            tmp = "%s.tmp%d" % (dest, os.getpid())
            shutil.rmtree(tmp, ignore_errors=True)
            shutil.copytree(d, tmp)
            try:
                os.replace(tmp, dest)
            except OSError:
                shutil.rmtree(tmp, ignore_errors=True)
            if os.path.isdir(dest) and _data_signature(dest) == sig:
                return dest
        except Exception:
            continue
    raise RuntimeError("espeak-ng 데이터를 ASCII 경로로 옮기지 못했어요.")


def _init(work_dir=None):
    global _backend, _SEP
    if _backend is not None:
        return
    import espeakng_loader
    from phonemizer.backend.espeak.wrapper import EspeakWrapper
    import phonemizer.backend.espeak.wrapper as W
    d = espeakng_loader.get_data_path()
    if not _ascii(d):
        ascii_dir = ascii_data_dir(d, work_dir)
        _orig = W.EspeakAPI
        W.EspeakAPI = lambda lib, dp: _orig(lib, ascii_dir)
    EspeakWrapper.set_library(espeakng_loader.get_library_path())
    from phonemizer.backend import EspeakBackend
    from phonemizer.separator import Separator
    _backend = EspeakBackend("en-us", preserve_punctuation=False, with_stress=True, language_switch="remove-flags")
    _SEP = Separator(word=" ", phone="", syllable="")


def ipa_one(word, work_dir=None):
    _init(work_dir)
    try:
        return _backend.phonemize([word], separator=_SEP, strip=True)[0].strip()
    except Exception:
        return ""


def ipa_batch(words, work_dir=None, chunk=400):
    """{word: ipa} for every word (ipa may be "" if espeak gave nothing). Returns (dict, n_single_fallbacks)."""
    _init(work_dir)
    out = {}
    single = 0
    for i in range(0, len(words), chunk):
        part = words[i:i + chunk]
        try:
            res = _backend.phonemize(part, separator=_SEP, strip=True)
        except Exception:
            res = None
        if res is not None and len(res) == len(part):
            for w, r in zip(part, res):
                out[w] = r.strip()
        else:
            for w in part:
                out[w] = ipa_one(w, work_dir)
                single += 1
    return out, single
