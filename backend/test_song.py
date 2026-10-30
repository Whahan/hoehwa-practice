# -*- coding: utf-8 -*-
"""Tests of song.py (song study K5: upload / job queue / result / enrich API). In-process by default: no server, no port, no model, no
network. The Whisper is the fake of song.py (HOEHWA_SONG_FAKE_ASR) or a scripted model; the LLM and readmode are song.fake_helpers().
Lyrics used here are written for this test (no real songs); the music is synthetic (sine + noise) made with PyAV.

  .venv\\Scripts\\python.exe -I test_song.py                 in-process tests (about 1-2 minutes: it builds a 460 s and a 66 MiB file)
  .venv\\Scripts\\python.exe -I test_song.py --stub PORT      additionally starts lan_stub_server.py --song on PORT (127.0.0.1, free port
                                                             required) and runs one upload -> job -> result -> release over real HTTP
  .venv\\Scripts\\python.exe -I test_song.py --base URL --song-file F.mp3 [--lyrics-json TRUTH.json]
                                                             live checks against a RUNNING server.py with the real models (a test server:
                                                             server.py --port N --tag x): one real job + /stt calls while it runs

Last line:  == test_song: N passed, 0 failed ==   (exit 0)
"""
import asyncio
import base64
import hashlib
import io
import json
import logging
import math
import os
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
from types import SimpleNamespace

os.environ["HOEHWA_TEST_HOOKS"] = "1"
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import numpy as np  # noqa: E402
import av  # noqa: E402
import httpx  # noqa: E402
from fastapi import FastAPI  # noqa: E402
from starlette.testclient import TestClient  # noqa: E402

import song  # noqa: E402
import song_align  # noqa: E402
import song_asr  # noqa: E402
import song_enrich  # noqa: E402

PASSED, FAILED, SKIPPED = [], [], []


def ok(name, cond, detail=""):
    (PASSED if cond else FAILED).append(name)
    print("  [%s] %s%s" % ("PASS" if cond else "FAIL", name, (" -- " + str(detail)[:300]) if (detail != "" and not cond) else ""))
    return bool(cond)


def skip(name, why):
    SKIPPED.append(name)
    print("  [SKIP] %s -- %s" % (name, why))


def arg(name, default=None):
    if name in sys.argv:
        i = sys.argv.index(name)
        if i + 1 < len(sys.argv):
            return sys.argv[i + 1]
    return default


MARK = "ZZSONGLINEZZ"
TMARK = "ZZTITLEZZ"
TMP = tempfile.mkdtemp(prefix="test_song_")
MiB = 1024 * 1024

# ----------------------------------------------------------------------------------------------
# log capture (the whole log of the run is searched for the marker strings)
# ----------------------------------------------------------------------------------------------
LOGBUF = io.StringIO()
_h = logging.StreamHandler(LOGBUF)
_h.setFormatter(logging.Formatter("%(name)s %(levelname)s %(message)s"))
LOG = logging.getLogger("k5test")
LOG.setLevel(logging.DEBUG)
LOG.propagate = False
LOG.addHandler(_h)
logging.getLogger().addHandler(_h)       # anything any module logs through the root logger
logging.getLogger().setLevel(logging.DEBUG)


# ----------------------------------------------------------------------------------------------
# synthetic audio (PyAV)
# ----------------------------------------------------------------------------------------------
FMT = {"mp3": ("mp3", "libmp3lame", "s16p"), "wav": ("wav", "pcm_s16le", "s16"), "flac": ("flac", "flac", "s16"),
       "m4a": ("ipod", "aac", "fltp"), "ogg": ("ogg", "libvorbis", "fltp"), "opus": ("ogg", "libopus", "s16")}


def gen_audio(path, sec, kind="mp3", sr=44100, ch=2, br=None, silent=False, seed=1):
    cont, codec, pf = FMT[kind]
    layout = "stereo" if ch == 2 else "mono"
    out = av.open(path, "w", format=cont)
    st = out.add_stream(codec, rate=sr)
    st.layout = layout
    if br:
        st.bit_rate = br
    rs = av.AudioResampler(format=pf, layout=layout, rate=sr)
    rng = np.random.RandomState(seed)
    total = int(sec * sr)
    done = 0
    while done < total:
        n = min(sr, total - done)
        t = (np.arange(n) + done) / float(sr)
        x = 0.25 * np.sin(2 * math.pi * (220 + 110 * ((done // sr) % 5)) * t) + 0.05 * rng.randn(n)
        if silent:
            x = x * 0.0
        arr = np.tile(x[None, :], (ch, 1)).astype(np.float32)
        fr = av.AudioFrame.from_ndarray(arr, format="fltp", layout=layout)
        fr.sample_rate = sr
        for f in rs.resample(fr):
            for p in st.encode(f):
                out.mux(p)
        done += n
    for f in rs.resample(None):
        for p in st.encode(f):
            out.mux(p)
    for p in st.encode(None):
        out.mux(p)
    out.close()
    return path


def probe(path):
    """(codec name, sample rate, channels, bit_rate, decoded seconds)"""
    with av.open(path) as c:
        s = c.streams.audio[0]
        cc = s.codec_context
        n = sum(f.samples for f in c.decode(s))
        return str(cc.name), int(cc.sample_rate), int(cc.channels), int(cc.bit_rate or 0), n / float(cc.sample_rate)


def sha(b):
    return hashlib.sha256(b).hexdigest()


def b64(b):
    return base64.b64encode(b).decode("ascii")


def new_uid():
    return os.urandom(16).hex()


# ----------------------------------------------------------------------------------------------
# app / helpers
# ----------------------------------------------------------------------------------------------
class Rig:
    """a fresh song.py (own job folder), a FastAPI app with only the song router, and a TestClient"""

    def __init__(self, ttl=None, delay=0.0, fake=True, extra=None, tag="r"):
        self.root = os.path.join(TMP, "jobs_%s_%d" % (tag, int(time.time() * 1000) % 10 ** 8))
        self.helpers = song.fake_helpers()
        self.helpers.update(extra or {})
        self.helpers["log"] = LOG
        song.init(root=self.root, ttl_sec=ttl, fake_asr=fake, fake_delay=delay, **self.helpers)
        self.app = FastAPI()
        self.app.include_router(song.router)
        self.c = TestClient(self.app)

    def post(self, path, body):
        return self.c.post(path, json=body)

    def get(self, path, **params):
        return self.c.get(path, params=params)

    def upload(self, data, name="a.mp3", uid=None, chunk=3 * MiB):
        uid = uid or new_uid()
        total = max(1, -(-len(data) // chunk))
        last = None
        for i in range(total):
            last = self.post("/song/upload", {"upload_id": uid, "index": i, "total": total, "name": name,
                                              "data_b64": b64(data[i * chunk:(i + 1) * chunk])})
            if last.status_code != 200:
                break
        return uid, last

    def job(self, uid, lang="en", lines=None, source=None, options=None, title="", artist="", lrclib_id=None):
        body = {"upload_id": uid, "lang": lang, "title": title, "artist": artist, "options": options or {}}
        if lines is not None:
            body["lyrics"] = {"source": source or "pasted", "lines": lines, "lrclib_id": lrclib_id}
        return self.post("/song/jobs", body)

    def status(self, jid):
        return self.get("/song/jobs/status", job=jid).json()

    def wait(self, jid, timeout=60.0, states=("done", "failed", "cancelled")):
        t0 = time.time()
        seen = []
        while time.time() - t0 < timeout:
            r = self.get("/song/jobs/status", job=jid)
            if r.status_code != 200:
                return r.json(), seen
            s = r.json()
            seen.append((s["state"], s["pct"]))
            if s["state"] in states:
                return s, seen
            time.sleep(0.05)
        return {"state": "timeout"}, seen

    def result(self, jid):
        return self.get("/song/result", job=jid)

    def audio_bytes(self, jid):
        first = self.get("/song/audio", job=jid, part=0).json()
        parts = [base64.b64decode(first["data_b64"])]
        for p in range(1, first["parts"]):
            parts.append(base64.b64decode(self.get("/song/audio", job=jid, part=p).json()["data_b64"]))
        return b"".join(parts), first

    def listing(self):
        return sorted(os.listdir(self.root)) if os.path.isdir(self.root) else []


def settle(timeout=15.0):
    """wait until no song-job thread is alive (every test leaves the module idle for the next Rig)"""
    t0 = time.time()
    while time.time() - t0 < timeout:
        if not any(t.name == "song-job" and t.is_alive() for t in threading.enumerate()):
            return True
        time.sleep(0.05)
    return False


def cancel_all(rig):
    for jid in list(song.JOBS):
        rig.post("/song/jobs/cancel", {"job": jid})
    settle()


def lyric_lines(n=6, words=4, base="alpha", t0=None, step=None):
    out = []
    for k in range(n):
        txt = " ".join("%s%s%d" % (base, chr(97 + k), j) for j in range(words))
        out.append({"text": txt, "t": None if t0 is None else round(t0 + k * step, 3), "p": k // 3})
    return out


def has_hangul(s):
    return bool(re.search("[가-힣]", s or ""))


LINKS = []


def make_link(link, target):
    """directory junction (Windows) or symlink; returns True when it exists afterwards"""
    LINKS.append(link)
    try:
        import _winapi
        _winapi.CreateJunction(target, link)
    except Exception:
        try:
            os.symlink(target, link, target_is_directory=True)
        except Exception:
            return False
    return os.path.lexists(link)


def snapshot(path):
    out = []
    for dp, dn, fn in os.walk(path):
        for n in dn + fn:
            out.append(os.path.relpath(os.path.join(dp, n), path))
    return sorted(out)


# ----------------------------------------------------------------------------------------------
print("== building synthetic audio ==")
t_gen = time.time()
BIG = gen_audio(os.path.join(TMP, "big.mp3"), 460.0, "mp3", 44100, 2, 128000)       # about 7.0 MiB, CBR 128k stereo
SMALL = gen_audio(os.path.join(TMP, "small.mp3"), 30.0, "mp3", 44100, 2, 128000)
MID = gen_audio(os.path.join(TMP, "mid.mp3"), 100.0, "mp3", 44100, 2, 128000)        # 5 windows of 20 s
SHORT = gen_audio(os.path.join(TMP, "short.mp3"), 0.4, "mp3", 44100, 2, 128000)
LONG = gen_audio(os.path.join(TMP, "long.mp3"), 11 * 60.0, "mp3", 22050, 1, 32000)  # 11 minutes
SILENT = gen_audio(os.path.join(TMP, "silent.mp3"), 30.0, "mp3", 44100, 2, 128000, silent=True)
big_b, small_b, mid_b, short_b, long_b, silent_b = [open(p, "rb").read() for p in (BIG, SMALL, MID, SHORT, LONG, SILENT)]
print("   built in %.1f s: big %.2f MiB, long %.2f MiB" % (time.time() - t_gen, len(big_b) / MiB, len(long_b) / MiB))

# ====================================================================================================================
print("== K5-14 constants (design 5.1) ==")
src = open(os.path.join(HERE, "song.py"), encoding="utf-8").read()
for name, expr in (("MAX_SONG_BYTES", "64 * 1024 * 1024"), ("MAX_SONG_SEC", "600"), ("CHUNK_BYTES", "3 * 1024 * 1024"), ("MAX_LINES", "400"),
                   ("MAX_LINE_CHARS", "200"), ("MAX_LYRIC_CHARS", "20000"), ("QUEUE_MAX", "3"), ("UPLOAD_TTL", "2 * 3600"),
                   ("JOB_TTL", "24 * 3600"), ("FOLDER_MAX", "1024 * 1024 * 1024")):
    ok("source line %s = %s" % (name, expr), re.search(r"^%s = %s\b" % (name, re.escape(expr)), src, re.M) is not None)
ok("constants have the numeric values of 5.1", (song.MAX_SONG_BYTES, song.MAX_SONG_SEC, song.CHUNK_BYTES, song.MAX_LINES, song.MAX_LINE_CHARS,
                                                 song.MAX_LYRIC_CHARS, song.QUEUE_MAX, song.UPLOAD_TTL, song.JOB_TTL, song.FOLDER_MAX)
   == (67108864, 600, 3145728, 400, 200, 20000, 3, 7200, 86400, 1073741824))

# ====================================================================================================================
print("== K5-2 chunked upload (7 MiB MP3 = 3 + 3 + 1 MiB) ==")
rig = Rig(tag="up")
uid = new_uid()
n_chunks = -(-len(big_b) // (3 * MiB))
resp = []
for i in range(n_chunks):
    resp.append(rig.post("/song/upload", {"upload_id": uid, "index": i, "total": n_chunks, "name": "big.mp3", "data_b64": b64(big_b[i * 3 * MiB:(i + 1) * 3 * MiB])}))
ok("file is 3 chunks of 3 MiB + 3 MiB + the rest", n_chunks == 3 and len(big_b) > 6 * MiB and len(big_b) < 8 * MiB, (n_chunks, len(big_b)))
ok("chunk 0 and 1 answer received/bytes (200)", [r.status_code for r in resp] == [200, 200, 200] and resp[0].json() == {"upload_id": uid, "received": 1, "bytes": 3 * MiB}
   and resp[1].json()["received"] == 2, [r.json() for r in resp[:2]])
fin = resp[-1].json()
true_dur = probe(BIG)[4]
ok("last answer: done true, format mp3, bytes", fin.get("done") is True and fin.get("format") == "mp3" and fin.get("bytes") == len(big_b), fin)
ok("duration within 0.05 s of the real length (%.3f vs %.3f)" % (fin.get("duration", -1), true_dur), abs(fin.get("duration", -1) - true_dur) <= 0.05)
ok("sha256 equals the file's SHA-256 (Get-FileHash)", fin.get("sha256") == sha(big_b), fin.get("sha256"))
ok("the MP3 that is already 44.1 kHz / 128k stereo is kept byte for byte", os.path.getsize(os.path.join(rig.root, "u_" + uid, "audio.mp3")) == len(big_b))
ok("no source copy is left next to the audio", sorted(os.listdir(os.path.join(rig.root, "u_" + uid))) == ["audio.mp3", "meta.json"], os.listdir(os.path.join(rig.root, "u_" + uid)))

print("== K5-3 order, repeats, resume ==")
uid3 = new_uid()
r0 = rig.post("/song/upload", {"upload_id": uid3, "index": 2, "total": 3, "name": "a.mp3", "data_b64": b64(b"x" * 10)})
ok("new upload that starts at index 2 -> 409 upload_gap expected 0", r0.status_code == 409 and r0.json().get("code") == "upload_gap" and r0.json().get("expected") == 0, r0.json())
big_parts = [small_b[:100000], small_b[100000:200000], small_b[200000:]]
rA = rig.post("/song/upload", {"upload_id": uid3, "index": 0, "total": 3, "name": "a.mp3", "data_b64": b64(big_parts[0])})
r2 = rig.post("/song/upload", {"upload_id": uid3, "index": 2, "total": 3, "name": "a.mp3", "data_b64": b64(big_parts[2])})
ok("index 2 before index 1 -> 409 upload_gap + expected 1 (and a Korean message)", r2.status_code == 409 and r2.json().get("code") == "upload_gap" and r2.json().get("expected") == 1
   and has_hangul(r2.json().get("error")), r2.json())
rA2 = rig.post("/song/upload", {"upload_id": uid3, "index": 0, "total": 3, "name": "a.mp3", "data_b64": b64(big_parts[0])})
ok("the same chunk again -> 200 (idempotent), bytes unchanged", rA.status_code == 200 and rA2.status_code == 200 and rA2.json()["bytes"] == 100000 and rA2.json()["received"] == 1, rA2.json())
g = rig.get("/song/upload", upload_id=uid3).json()
ok("GET /song/upload tells where to resume", g == {"upload_id": uid3, "next": 1, "bytes": 100000, "done": False}, g)
rig2 = Rig(tag="up2")        # a different job root: nothing there
ok("GET /song/upload of an unknown upload -> 404 no_upload", rig2.get("/song/upload", upload_id=uid3).status_code == 404)
# resume after a server restart: same root, registry rebuilt from disk
song.init(root=rig.root, fake_asr=True, **rig.helpers)
g2 = rig.get("/song/upload", upload_id=uid3).json()
ok("after a restart the upload is still known (resume works)", g2.get("next") == 1 and g2.get("bytes") == 100000, g2)
rB = rig.post("/song/upload", {"upload_id": uid3, "index": 1, "total": 3, "name": "a.mp3", "data_b64": b64(big_parts[1])})
rC = rig.post("/song/upload", {"upload_id": uid3, "index": 2, "total": 3, "name": "a.mp3", "data_b64": b64(big_parts[2])})
ok("...and finishing it works", rB.status_code == 200 and rC.status_code == 200 and rC.json().get("done") is True and rC.json().get("sha256") == sha(small_b), rC.json())
rD = rig.post("/song/upload", {"upload_id": uid3, "index": 2, "total": 3, "name": "a.mp3", "data_b64": b64(big_parts[2])})
ok("the last chunk again after done -> 200 with the same answer", rD.status_code == 200 and rD.json() == rC.json())

print("== normalisation of other formats ==")
for kind, sr_, ch_ in (("wav", 22050, 1), ("flac", 48000, 2), ("m4a", 44100, 2), ("opus", 48000, 2)):
    p = os.path.join(TMP, "n_%s.%s" % (kind, kind))
    try:
        gen_audio(p, 20.0, kind, sr_, ch_)
    except Exception as e:
        skip("upload of %s" % kind, "this PyAV cannot encode it (%s)" % type(e).__name__)
        continue
    b = open(p, "rb").read()
    uid_, r = rig.upload(b, "n." + kind)
    d = r.json()
    apath = os.path.join(rig.root, "u_" + uid_, "audio.mp3")
    info = probe(apath) if os.path.exists(apath) else None
    ok("%s (%d Hz, %d ch) -> MP3 128k / 44.1 kHz, same channel count, ~20 s" % (kind, sr_, ch_),
       r.status_code == 200 and d.get("done") and info and info[0].startswith("mp3") and info[1] == 44100 and info[2] == ch_
       and 120000 <= info[3] <= 136000 and abs(info[4] - 20.0) <= 0.2 and abs(d["duration"] - 20.0) <= 0.2 and d["sha256"] == sha(open(apath, "rb").read()),
       (d, info))
k6 = r"C:\Users\rtyu6\AppData\Local\Temp\claude\D--Ai---\9cb41c31-c114-4117-abfc-6c62dfb3d0b7\scratchpad\w_ss_k6\gen\song_en_snr5"
for ext in ("m4a", "flac", "ogg", "wav", "mp3"):
    p = "%s.%s" % (k6, ext)
    if not os.path.exists(p):
        skip("K6 test song .%s" % ext, "file not found (read-only fixture of K6)")
        continue
    uid_, r = rig.upload(open(p, "rb").read(), "k6." + ext)
    ok("K6 synthetic song .%s uploads (duration ~20.7 s)" % ext, r.status_code == 200 and abs(r.json().get("duration", 0) - 20.69) <= 0.3, r.json())

print("== K5-4 / K5-5 limits and bad input ==")
before = rig.listing()
uidg, rg = rig.upload(os.urandom(200000), "x.mp3")
ok("random bytes as x.mp3 -> 415 bad_audio with a Korean message", rg.status_code == 415 and rg.json().get("code") == "bad_audio" and has_hangul(rg.json().get("error")), rg.json())
ok("...and the upload folder is deleted", not os.path.exists(os.path.join(rig.root, "u_" + uidg)) and rig.listing() == before, rig.listing())
ok("...and it is gone from the registry (GET -> 404)", rig.get("/song/upload", upload_id=uidg).status_code == 404)
uids, rs = rig.upload(short_b, "s.mp3")
ok("a 0.4 s file is not a song -> 415 bad_audio", rs.status_code == 415 and rs.json().get("code") == "bad_audio", rs.json())
uidl, rl = rig.upload(long_b, "long.mp3")
ok("11 minutes -> 413 too_long (Korean), folder deleted", rl.status_code == 413 and rl.json().get("code") == "too_long" and has_hangul(rl.json().get("error"))
   and not os.path.exists(os.path.join(rig.root, "u_" + uidl)), rl.json())
uidt, rt = rig.upload(small_b, "notes.txt")
ok("a .txt name -> 415 bad_audio", rt.status_code == 415 and rt.json().get("code") == "bad_audio", rt.json())
uidu, ru = rig.upload(small_b, "UPPER.MP3")
ok("upper-case extension is fine", ru.status_code == 200 and ru.json().get("done"), ru.json())
bad = [({"upload_id": new_uid(), "index": 0, "total": 1, "name": "a.mp3", "data_b64": "!!!not base64!!!"}, "bad base64"),
       ({"upload_id": new_uid(), "index": 0, "total": 1, "name": "a.mp3", "data_b64": ""}, "empty data"),
       ({"upload_id": new_uid(), "index": "0", "total": 1, "name": "a.mp3", "data_b64": b64(b"x")}, "index is a string"),
       ({"upload_id": new_uid(), "index": 0, "total": 0, "name": "a.mp3", "data_b64": b64(b"x")}, "total 0"),
       ({"upload_id": new_uid(), "index": 0, "total": 10 ** 6, "name": "a.mp3", "data_b64": b64(b"x")}, "total too big"),
       ({"upload_id": new_uid(), "index": 0, "total": 1, "data_b64": b64(b"x")}, "no name"),
       ({"upload_id": new_uid(), "index": 0, "total": 1, "name": 5, "data_b64": b64(b"x")}, "name is a number"),
       ({"upload_id": new_uid(), "index": 0, "total": 1, "name": "a.mp3", "data_b64": 5}, "data is a number"),
       ({"upload_id": new_uid(), "index": 0, "total": 1, "name": "a.mp3", "data_b64": b64(b"x" * (3 * MiB + 1))}, "chunk of 3 MiB + 1")]
for body, label in bad:
    r = rig.post("/song/upload", body)
    ok("bad upload request (%s) -> 400 with code" % label, r.status_code == 400 and r.json().get("code") in ("bad_request", "bad_index") and has_hangul(r.json().get("error")), (r.status_code, r.json()))
rbj = rig.c.post("/song/upload", content=b"{broken json", headers={"content-type": "application/json"})
ok("broken JSON body -> 400 bad_request (not FastAPI's 422)", rbj.status_code == 400 and rbj.json().get("code") == "bad_request", (rbj.status_code, rbj.text))
rbl = rig.c.post("/song/upload", content=b"[1,2]", headers={"content-type": "application/json"})
ok("a JSON list as body -> 400 bad_request", rbl.status_code == 400 and rbl.json().get("code") == "bad_request")
r_idx = rig.post("/song/upload", {"upload_id": new_uid(), "index": 3, "total": 3, "name": "a.mp3", "data_b64": b64(b"x")})
ok("index >= total -> 400 bad_index", r_idx.status_code == 400 and r_idx.json().get("code") == "bad_index", r_idx.json())

# 66 MiB (22 x 3 MiB) with the real limit: the 22nd chunk crosses 64 MiB
junk = os.urandom(3 * MiB)
uid64 = new_uid()
codes, last = [], None
t_up = time.time()
for i in range(22):
    last = rig.post("/song/upload", {"upload_id": uid64, "index": i, "total": 22, "name": "huge.mp3", "data_b64": b64(junk)})
    codes.append(last.status_code)
    if last.status_code != 200:
        break
ok("K5-4: the chunk that makes the total pass 64 MiB -> 413 too_large (after 21 x 200, %.1f s)" % (time.time() - t_up),
   codes == [200] * 21 + [413] and last.json().get("code") == "too_large" and has_hangul(last.json().get("error")), (codes, last.json()))
ok("K5-4: the upload folder is deleted and unknown", not os.path.exists(os.path.join(rig.root, "u_" + uid64)) and rig.get("/song/upload", upload_id=uid64).status_code == 404)

print("== K5-6 dangerous ids ==")
outer_before = snapshot(TMP)
evil_up = ["../x", "..\\x", "A" * 32, "a" * 31, "a" * 33, "g" * 32, "", "%2e%2e%2f" + "a" * 23, "a" * 32 + "/../..", None, 5, ["a" * 32]]
res_up = []
for e in evil_up:
    res_up.append(rig.post("/song/upload", {"upload_id": e, "index": 0, "total": 1, "name": "a.mp3", "data_b64": b64(b"x")}).status_code)
    res_up.append(rig.post("/song/jobs", {"upload_id": e, "lang": "en"}).status_code)
ok("upload_id '../x', upper-case, 31 / 33 chars, non-hex, empty, non-strings -> 400 everywhere", set(res_up) == {400}, res_up)
evil_job = ["../x", "J_00000000", "j_0000000", "j_000000000", "j_0000000G", "j_00000000/..", "../../j_00000000", "", None, 7]
res_job = []
for e in evil_job:
    for path, how in (("/song/jobs/status", "get"), ("/song/result", "get"), ("/song/audio", "get")):
        res_job.append(rig.get(path, job=e).status_code if e is not None and not isinstance(e, int) else rig.get(path).status_code)
    res_job.append(rig.post("/song/jobs/cancel", {"job": e}).status_code)
    res_job.append(rig.post("/song/jobs/release", {"job": e}).status_code)
ok("job '../x', upper-case, wrong length, non-hex, empty, non-strings -> 400 everywhere", set(res_job) == {400}, res_job)
ok("nothing was created or removed anywhere (before/after listing of the whole temp tree incl. the job folder)", snapshot(TMP) == outer_before, sorted(set(snapshot(TMP)) ^ set(outer_before))[:5])
ok("a missing job id -> 400, an unknown valid one -> 404 no_job", rig.get("/song/jobs/status").status_code == 400
   and rig.get("/song/jobs/status", job="j_00000000").status_code == 404 and rig.get("/song/jobs/status", job="j_00000000").json().get("code") == "no_job")

# ====================================================================================================================
print("== K5-7 job lifecycle with the fake Whisper (pasted lyrics) ==")
rig = Rig(tag="job", delay=0.05)
uid, r = rig.upload(mid_b, "mid.mp3")
lines = [{"text": "%s line one hello again" % MARK, "t": None, "p": 0}, {"text": "second line walks along", "t": None, "p": 0},
         {"text": "", "t": None, "p": 0}, {"text": "third line in the new verse", "t": None, "p": 1}]
rj = rig.job(uid, "en", lines, "pasted", {"translate": True, "gloss": True, "ai_ok": True}, title=TMARK + " title", artist="Some Artist")
jid = rj.json().get("job", "")
ok("POST /song/jobs -> 202 {job j_8hex, state queued, queue_pos 0}", rj.status_code == 202 and re.fullmatch(r"j_[0-9a-f]{8}", jid) and rj.json().get("state") == "queued"
   and rj.json().get("queue_pos") == 0, rj.json())
st, seen = rig.wait(jid)
states = [s for s, _ in seen]
pcts = [p for _, p in seen]
ok("state goes queued/running -> done", st["state"] == "done" and "running" in states + ["running"] and states[-1] == "done", states[:3] + states[-2:])
ok("pct never goes down and reaches 100", pcts == sorted(pcts) and pcts[-1] == 100 and st["pct"] == 100, pcts)
ok("status has job/state/stage/pct/eta_sec/message_ko/warnings/error (message in Korean)",
   set(st) >= {"job", "state", "stage", "pct", "eta_sec", "message_ko", "warnings", "error"} and has_hangul(st["message_ko"]) and st["error"] is None and st["job"] == jid, st)
res = rig.result(jid)
song_json = res.json()
ok("GET /song/result -> the song JSON (v 1, no id, lines >= 1)", res.status_code == 200 and song_json.get("v") == 1 and "id" not in song_json and len(song_json.get("lines", [])) >= 1, list(song_json)[:12])
need = {"v", "lang", "title", "artist", "created", "duration", "audio", "source", "offset", "lines", "glossary", "marks", "stats", "warnings", "app"}
ok("all 5.2 top-level keys are there", need <= set(song_json), need - set(song_json))
ln0 = song_json["lines"][0]
ok("a line has i p t0 t1 text reading pron ko conf est stale words", {"i", "p", "t0", "t1", "text", "reading", "pron", "ko", "conf", "est", "stale", "words"} <= set(ln0), set(ln0))
w0 = ln0["words"][0]
ok("a word has w lemma level zipf s e est content", {"w", "lemma", "level", "zipf", "s", "e", "est", "content"} <= set(w0), set(w0))
ok("three non-blank lyric lines -> three lines, blank line skipped, stanza p kept", [l["p"] for l in song_json["lines"]] == [0, 0, 1] and len(song_json["lines"]) == 3, [l["p"] for l in song_json["lines"]])
ok("K2 invariants hold for the result (0 <= t0 < t1 <= duration, ascending, words inside)", song_align.check_lines(song_json["lines"], song_json["duration"]) == [], song_align.check_lines(song_json["lines"], song_json["duration"]))
ok("source: pasted / word timing / no attribution; offset 0.0; app string", song_json["source"] == {"lyrics": "pasted", "lrclib_id": None, "timing": "word", "attribution": ""}
   and song_json["offset"] == 0.0 and isinstance(song_json["app"], str), song_json["source"])
ok("title and artist are carried", song_json["title"] == TMARK + " title" and song_json["artist"] == "Some Artist")
ok("fake AI answers (ai_ok true): ko is Korean on every line, glossary has entries", all(has_hangul(l["ko"]) for l in song_json["lines"]) and len(song_json["glossary"]) >= 1
   and "ko_missing" not in song_json["warnings"], (song_json["glossary"], song_json["warnings"]))
ok("every AI call asked for cache_key_kind=None (no lyrics in the persistent cache)", rig.helpers["llm_calls"] and all(k is None for k in rig.helpers["llm_calls"]), rig.helpers["llm_calls"])
audio, first = rig.audio_bytes(jid)
ok("K5-7: /song/audio parts glued together hash to audio.sha256 and to the uploaded MP3", sha(audio) == song_json["audio"]["sha256"] == first["sha256"] == sha(mid_b)
   and first["parts"] == song_json["audio"]["parts"] == 1 and song_json["audio"]["bytes"] == len(mid_b), (first["parts"], song_json["audio"]))

def parts_hash_ok(parts, want):
    return sha(b"".join(parts)) == want
tampered = bytearray(audio)
tampered[len(tampered) // 2] ^= 0x01
ok("checker self-test: one flipped byte in the downloaded MP3 is caught (sha mismatch)", not parts_hash_ok([bytes(tampered)], song_json["audio"]["sha256"]) and parts_hash_ok([audio], song_json["audio"]["sha256"]))

rbig = Rig(tag="job2", delay=0.0)
uidb, rb_ = rbig.upload(big_b, "big.mp3")
jb = rbig.job(uidb, "en", None).json()["job"]
stb, _ = rbig.wait(jb, timeout=90)
audb, fb = rbig.audio_bytes(jb)
ok("a 7 MiB song comes back in 3 audio parts (3 MiB each but the last) with the same hash", stb["state"] == "done" and fb["parts"] == 3 and sha(audb) == sha(big_b) == fb["sha256"] and fb["bytes"] == 3 * MiB, (stb, fb["parts"], fb["bytes"]))
pbad = [rbig.get("/song/audio", job=jb, part=p).status_code for p in (-1, 3, 99)] + [rbig.get("/song/audio", job=jb, part="abc").status_code]
ok("part out of range / not a number -> 400 bad_index", pbad == [400, 400, 400, 400] and rbig.get("/song/audio", job=jb, part=9).json().get("code") == "bad_index", pbad)

print("== ai_ok = false: no AI call at all (12.1b) ==")
rig = Rig(tag="noai", delay=0.0)
uid, r = rig.upload(small_b, "a.mp3")
jid = rig.job(uid, "en", lyric_lines(5), "pasted", {"translate": True, "gloss": True, "ai_ok": False}).json()["job"]
st, _ = rig.wait(jid)
sj = rig.result(jid).json()
ok("ai_ok false: the LLM was called 0 times and readmode.gloss 0 times", rig.helpers["llm_calls"] == [] and rig.helpers["readmode"].gloss_calls == 0, (rig.helpers["llm_calls"], rig.helpers["readmode"].gloss_calls))
ok("...ko is '' on every line, warnings ko_missing + gloss_missing, glossary empty, job still done", st["state"] == "done" and all(l["ko"] == "" for l in sj["lines"]) and "ko_missing" in sj["warnings"]
   and "gloss_missing" in sj["warnings"] and sj["glossary"] == {}, sj["warnings"])
uid, r = rig.upload(small_b, "a.mp3")
jid = rig.job(uid, "en", lyric_lines(5), "pasted", {"translate": True, "gloss": True}).json()["job"]       # ai_ok missing = false
rig.wait(jid)
ok("ai_ok missing in options counts as false (0 AI calls)", rig.helpers["llm_calls"] == [] and rig.helpers["readmode"].gloss_calls == 0)
uid, r = rig.upload(small_b, "a.mp3")
jid = rig.job(uid, "en", lyric_lines(5), "pasted", {"translate": False, "gloss": False, "ai_ok": True}).json()["job"]
st, _ = rig.wait(jid)
sj = rig.result(jid).json()
ok("ai_ok true but translate/gloss off: still 0 AI calls, no ko_missing warning", st["state"] == "done" and rig.helpers["llm_calls"] == [] and "ko_missing" not in sj["warnings"] and "gloss_missing" not in sj["warnings"], sj["warnings"])
uid, r = rig.upload(small_b, "a.mp3")
jid = rig.job(uid, "en", lyric_lines(5), "pasted", {"ai_ok": True}).json()["job"]
rig.wait(jid)
ok("ai_ok true with the default options (translate + gloss on): the AI is used", len(rig.helpers["llm_calls"]) >= 1 and rig.helpers["readmode"].gloss_calls >= 1, (rig.helpers["llm_calls"], rig.helpers["readmode"].gloss_calls))
for bad_opt in ({"ai_ok": "yes"}, {"translate": 1}, {"gloss": None}, {"verify": "true"}):
    uid_b, _ = rig.upload(small_b, "a.mp3")
    r = rig.job(uid_b, "en", None, None, bad_opt)
    ok("non-boolean option %s -> 400 bad_request" % bad_opt, r.status_code == 400 and r.json().get("code") == "bad_request", r.json())

print("== lyrics checks ==")
uid, r = rig.upload(small_b, "a.mp3")
r400 = rig.job(uid, "en", [{"text": "x%d" % k, "t": None, "p": 0} for k in range(400)])
ok("400 lyric lines are accepted", r400.status_code == 202, r400.json())
cancel_all(rig)
r401 = rig.job(uid, "en", [{"text": "x%d" % k, "t": None, "p": 0} for k in range(401)])
ok("401 lyric lines -> 400 bad_request (Korean message)", r401.status_code == 400 and r401.json().get("code") == "bad_request" and has_hangul(r401.json().get("error")), r401.json())
r20k = rig.job(uid, "en", [{"text": "y" * 200, "t": None, "p": 0} for _ in range(101)])
ok("more than 20000 characters in total -> 400 bad_request", r20k.status_code == 400 and r20k.json().get("code") == "bad_request", r20k.json())
rbadlang = rig.job(uid, "fr", None)
ok("lang 'fr' -> 400", rbadlang.status_code == 400 and rbadlang.json().get("code") == "bad_request")
for bad_lines, label in (("not a list", "lines is a string"), ([5], "a line is a number"), ([{"text": 5}], "text is a number"), ([{"text": "a", "t": "1"}], "t is a string"),
                         ([{"text": "a", "t": float("nan")}], "t is NaN"), ([{"text": "a", "t": -1}], "t is negative"), ([{"text": "a", "p": -1}], "p is negative"),
                         ([{"text": "a", "p": True}], "p is a bool")):
    body = {"upload_id": uid, "lang": "en", "lyrics": {"source": "pasted", "lines": bad_lines}}
    try:
        r = rig.c.post("/song/jobs", content=json.dumps(body).encode("utf-8"), headers={"content-type": "application/json"})
    except Exception as e:
        r = SimpleNamespace(status_code=-1, json=lambda: {"code": type(e).__name__})
    ok("bad lyrics (%s) -> 400" % label, r.status_code == 400 and r.json().get("code") == "bad_request", (r.status_code, r.json()))
rsrc = rig.post("/song/jobs", {"upload_id": uid, "lang": "en", "lyrics": {"source": "spotify", "lines": []}})
ok("unknown lyrics source -> 400", rsrc.status_code == 400)
rlong = rig.job(uid, "en", [{"text": "w" * 260, "t": None, "p": 0}, {"text": "short one", "t": None, "p": 0}])
jl = rlong.json()["job"]
rig.wait(jl)
sl = rig.result(jl).json()
ok("a line longer than 200 characters is cut to 200 with the lyrics_truncated warning", rlong.status_code == 202 and len(sl["lines"][0]["text"]) <= 200 and "lyrics_truncated" in sl["warnings"], sl["warnings"])
rnone = rig.post("/song/jobs", {"upload_id": new_uid(), "lang": "en"})
ok("a job for an upload that does not exist -> 404 no_upload", rnone.status_code == 404 and rnone.json().get("code") == "no_upload")
uid_half = new_uid()
rig.post("/song/upload", {"upload_id": uid_half, "index": 0, "total": 2, "name": "a.mp3", "data_b64": b64(small_b[:1000])})
rhalf = rig.post("/song/jobs", {"upload_id": uid_half, "lang": "en"})
ok("a job for an unfinished upload -> 409 upload_gap", rhalf.status_code == 409 and rhalf.json().get("code") == "upload_gap" and rhalf.json().get("expected") == 1, rhalf.json())
uidn, rn = rig.upload(small_b, "a.mp3")
jn = rig.job(uidn, "en", None, options={"translate": False, "gloss": False}).json()["job"]
stn, _ = rig.wait(jn)
sn = rig.result(jn).json()
ok("no lyrics: lines come from the (fake) recognised words, source asr, no ko needed", stn["state"] == "done" and len(sn["lines"]) >= 1 and sn["source"]["lyrics"] == "asr"
   and song_align.check_lines(sn["lines"], sn["duration"]) == [], (stn, sn["source"]))
jn2 = rig.job(uidn, "en", [{"text": "THIS MUST NOT APPEAR", "t": None, "p": 0}], "none", {"translate": False, "gloss": False}).json()["job"]
rig.wait(jn2)
ok("lyrics.source 'none' ignores the lines it carries (the song has no such line)", "THIS MUST NOT APPEAR" not in json.dumps(rig.result(jn2).json()))

print("== LRC lines (times given): offset estimate, verify off ==")
rig = Rig(tag="lrc", delay=0.0)
# the fake Whisper "hears" every lyric word at 0.3 + i * 0.5 s (4 words per line = 2 s per line); give LRC times 1.2 s too early
n_l = 14
lrc_lines = lyric_lines(n_l, 4, "lrc", t0=0.3 - 1.2 + 0.0, step=2.0)
lrc_lines[0]["t"] = 0.0
uid, r = rig.upload(mid_b, "mid.mp3")
jid = rig.job(uid, "en", lrc_lines, "lrclib", {"translate": False, "gloss": False, "verify": True}, lrclib_id=4711).json()["job"]
st, _ = rig.wait(jid)
sj = rig.result(jid).json()
ok("LRC mode finishes done with timing line, source lrclib, lrclib_id kept, attribution text", st["state"] == "done" and sj["source"]["timing"] == "line" and sj["source"]["lyrics"] == "lrclib"
   and sj["source"]["lrclib_id"] == 4711 and "LRCLIB" in sj["source"]["attribution"], sj["source"])
ok("verify on (3 samples of a 100 s song): the +1.2 s offset is found, applied to t0 (line 3 at 0.3 - 1.2 + 2*2 + 1.2 = 4.3) and flagged offset_guess",
   "offset_guess" in sj["warnings"] and abs(sj["lines"][2]["t0"] - 4.3) <= 0.15, (sj["warnings"], [l["t0"] for l in sj["lines"]][:4]))
ok("K5 'offset' rule: the estimated offset is inside t0/t1, the song's offset field stays 0.0 (no double count)", sj["offset"] == 0.0)
ok("LRC lines keep est false for the line time and est true for words", all(l["est"] is False for l in sj["lines"]) and all(w["est"] for l in sj["lines"] for w in l["words"]), sj["lines"][0])
ok("est_times warning is there for LRC timing", "est_times" in sj["warnings"], sj["warnings"])
rig.helpers["llm_calls"].clear()
uid, r = rig.upload(mid_b, "mid.mp3")
spy_calls = []
real_tr = song_asr.transcribe_song
song_asr.transcribe_song = lambda *a, **k: (spy_calls.append(1), real_tr(*a, **k))[1]
jid = rig.job(uid, "en", lrc_lines, "lrclib", {"translate": False, "gloss": False, "verify": False}).json()["job"]
st, _ = rig.wait(jid)
sj2 = rig.result(jid).json()
song_asr.transcribe_song = real_tr
ok("verify off: Whisper is not run at all and the LRC times are used as given", st["state"] == "done" and spy_calls == [] and abs(sj2["lines"][2]["t0"] - 3.1) <= 0.01
   and "offset_guess" not in sj2["warnings"], (spy_calls, sj2["lines"][2]["t0"]))
uid, r = rig.upload(mid_b, "mid.mp3")
exact = lyric_lines(n_l, 4, "lrc", t0=0.3, step=2.0)
jid = rig.job(uid, "en", exact, "lrclib", {"translate": False, "gloss": False, "verify": True}).json()["job"]
rig.wait(jid)
sj3 = rig.result(jid).json()
ok("times that already match: offset 0, no offset_guess warning", "offset_guess" not in sj3["warnings"] and abs(sj3["lines"][2]["t0"] - 4.3) <= 0.15, (sj3["warnings"], sj3["lines"][2]["t0"]))
uid, r = rig.upload(mid_b, "mid.mp3")
few = lyric_lines(3, 4, "few", t0=0.3 - 1.2, step=2.0)
few[0]["t"] = 0.0
jid = rig.job(uid, "en", few, "lrclib", {"translate": False, "gloss": False, "verify": True}).json()["job"]
rig.wait(jid)
sj4 = rig.result(jid).json()
ok("fewer than 5 supporting lines: offset 0 (no guess)", "offset_guess" not in sj4["warnings"], sj4["warnings"])

print("== Japanese: tokens first, contextual readings, reader injected ==")
rig = Rig(tag="ja", delay=0.0)
order = []
real_enrich, real_align, real_tr = song_enrich.enrich_lines, song_align.align_lyrics, song_asr.transcribe_song
seen_kw = {}


def spy_enrich(lang, lines, tasks, *a, **k):
    order.append("enrich:" + ",".join(tasks))
    return real_enrich(lang, lines, tasks, *a, **k)


def spy_tr(*a, **k):
    order.append("asr")
    seen_kw["reader"] = k.get("reader")
    return real_tr(*a, **k)


def spy_align(lyr, words, dur, lang, reader):
    order.append("align")
    seen_kw["lyr"] = lyr
    seen_kw["align_reader"] = reader
    seen_kw["words"] = words
    return real_align(lyr, words, dur, lang, reader)


song_enrich.enrich_lines, song_asr.transcribe_song, song_align.align_lyrics = spy_enrich, spy_tr, spy_align
uid, r = rig.upload(small_b, "ja.mp3")
ja_lyrics = [{"text": "きみがわらう", "t": None, "p": 0}, {"text": "そらをみる", "t": None, "p": 0}, {"text": "あさのまどべ", "t": None, "p": 1}]
jid = rig.job(uid, "ja", ja_lyrics, "pasted", {"translate": True, "gloss": False, "ai_ok": True}).json()["job"]
st, _ = rig.wait(jid)
song_enrich.enrich_lines, song_asr.transcribe_song, song_align.align_lyrics = real_enrich, real_tr, real_align
sj = rig.result(jid).json()
ok("ja: song_enrich tokens run BEFORE the recognition, the full enrichment after the alignment", order[0] == "enrich:tokens" and order.index("asr") < order.index("align") and order[-1].startswith("enrich:reading,tokens,translate"), order)
ok("ja: transcribe_song gets reader = ja_to_kata (contextual readings k)", seen_kw.get("reader") is rig.helpers["ja_to_kata"] and all("k" in w for w in seen_kw["words"]) if seen_kw.get("words") else False, seen_kw.get("reader"))
ok("ja: align_lyrics gets the lyric lines with tokens [{w, kata}] and the reader", all(isinstance(l.get("tokens"), list) and l["tokens"] and "w" in l["tokens"][0] for l in seen_kw["lyr"])
   and seen_kw["align_reader"] is rig.helpers["ja_to_kata"], seen_kw["lyr"][:1])
ok("ja: the kata of a token is a katakana string from the reader", all(re.fullmatch(r"[ァ-ヺー]+", t.get("kata", "ア")) for l in seen_kw["lyr"] for t in l["tokens"]), seen_kw["lyr"][0]["tokens"][:3])
ok("ja: reading is hiragana only, pron is katakana only (from the fake ja_reading / ja_pron)", st["state"] == "done" and all(re.fullmatch(r"[ぁ-ゖー ]+", l["reading"]) and re.fullmatch(r"[ァ-ヺー ]+", l["pron"]) for l in sj["lines"]),
   [(l["reading"], l["pron"]) for l in sj["lines"]])
ok("ja: words carry reading and lemma, and are the aligned tokens (times from the recognised characters)", all("reading" in w and w["lemma"] for l in sj["lines"] for w in l["words"]) and
   "".join(w["w"] for w in sj["lines"][0]["words"]) == "きみがわらう", sj["lines"][0]["words"])
seen_kw.clear()
song_asr.transcribe_song = spy_tr
uid, r = rig.upload(small_b, "en.mp3")
jid = rig.job(uid, "en", lyric_lines(3), "pasted", {"translate": False, "gloss": False}).json()["job"]
rig.wait(jid)
song_asr.transcribe_song = real_tr
ok("en: no reader passed to transcribe_song", seen_kw.get("reader") is None and "reader" in seen_kw)

print("== merged words (analysis tokens onto aligned words) ==")
mw = song._merge_words([{"w": "don't", "s": 0.0, "e": 0.5, "est": False}, {"w": "stop", "s": 0.6, "e": 1.0, "est": True}],
                       [{"w": "do", "lemma": "do", "level": "easy", "zipf": 6.3, "content": False}, {"w": "n't", "lemma": "not", "level": "easy", "zipf": 6.6, "content": False},
                        {"w": "stop", "lemma": "stop", "level": "mid", "zipf": 4.9, "content": True}], "en")
ok("don't = do + n't: one word with the first token's lemma, the next word follows", mw[0]["lemma"] == "do" and mw[1]["lemma"] == "stop" and mw[1]["est"] is True and mw[1]["content"] is True, mw)
chars = [{"w": c, "s": 0.1 * k, "e": 0.1 * k + 0.08, "est": k == 4} for k, c in enumerate("朝の窓辺")]
mj = song._merge_words(chars, [{"w": "朝", "lemma": "朝", "level": "easy", "zipf": 5.0, "content": True, "reading": "あさ"},
                               {"w": "の", "lemma": "の", "level": "easy", "zipf": 7.0, "content": False, "reading": "の"},
                               {"w": "窓辺", "lemma": "窓辺", "level": "hard", "zipf": 3.0, "content": True, "reading": "まどべ"}], "ja")
ok("ja: recognised characters are joined to the token they spell (times from the first and last character, reading kept)",
   [w["w"] for w in mj] == ["朝", "の", "窓辺"] and abs(mj[2]["s"] - 0.2) < 1e-9 and abs(mj[2]["e"] - 0.38) < 1e-9 and mj[2]["reading"] == "まどべ" and mj[2]["level"] == "hard", mj)
mj2 = song._merge_words(chars, [{"w": "別", "lemma": "別", "level": "easy", "zipf": 5.0, "content": True, "reading": "べつ"}], "ja")
ok("ja: tokens that do not spell the recognised characters leave the characters as they are (neutral defaults)", [w["w"] for w in mj2] == ["朝", "の", "窓", "辺"], mj2)
mw2 = song._merge_words([{"w": "zzz", "s": 0.0, "e": 0.5, "est": False}], [{"w": "other", "lemma": "other", "level": "hard", "zipf": 3.0, "content": True}], "en")
ok("a word no token matches gets neutral defaults (lemma = lower-case word, level mid, content true)", mw2[0]["lemma"] == "zzz" and mw2[0]["level"] == "mid" and mw2[0]["content"] is True, mw2)

# ====================================================================================================================
print("== K5-8 cancel ==")
rig = Rig(tag="cancel", delay=0.5)
uid, r = rig.upload(mid_b, "mid.mp3")
jid = rig.job(uid, "en", lyric_lines(5), "pasted", {"translate": False, "gloss": False}).json()["job"]
t0 = time.time()
while time.time() - t0 < 10 and rig.status(jid)["stage"] != "asr":
    time.sleep(0.05)
ok("the job runs (stage asr) with 0.5 s per window", rig.status(jid)["stage"] == "asr" and rig.status(jid)["state"] == "running")
tc = time.time()
rc = rig.post("/song/jobs/cancel", {"job": jid})
ok("cancel answers {ok true, state cancelled} at once", rc.status_code == 200 and rc.json() == {"ok": True, "state": "cancelled"} and time.time() - tc < 0.5, rc.json())
ok("the status says cancelled right away", rig.status(jid)["state"] == "cancelled")
t_end = time.time()
while time.time() - t_end < 3 and (os.path.exists(os.path.join(rig.root, jid)) or any(t.name == "song-job" and t.is_alive() for t in threading.enumerate())):
    time.sleep(0.05)
ok("within 3 s: the job folder is gone", not os.path.exists(os.path.join(rig.root, jid)), rig.listing())
ok("within 3 s: no 'song-job' thread is alive", not any(t.name == "song-job" and t.is_alive() for t in threading.enumerate()))
rr = rig.result(jid)
ok("result of a cancelled job -> 409 not_done", rr.status_code == 409 and rr.json().get("code") == "not_done", rr.json())
ok("the status stays 'cancelled' (not failed) and the audio part is not served", rig.status(jid)["state"] == "cancelled" and rig.get("/song/audio", job=jid, part=0).status_code == 409)
ok("the upload folder is still there (the same file can be started again)", os.path.isdir(os.path.join(rig.root, "u_" + uid)))
jid2 = rig.job(uid, "en", lyric_lines(3), "pasted", {"translate": False, "gloss": False}).json()["job"]
st2, _ = rig.wait(jid2, timeout=30)
ok("starting the same upload again after a cancel works and finishes", st2["state"] == "done", st2)
rig.post("/song/jobs/cancel", {"job": jid2})
ok("cancel of a finished job -> ok true, state stays done", rig.post("/song/jobs/cancel", {"job": jid2}).json() == {"ok": True, "state": "done"})
settle()

print("== K5-10 queue ==")
rig = Rig(tag="queue", delay=1.0)
ups = [rig.upload(mid_b, "m%d.mp3" % k)[0] for k in range(5)]
js = []
for k in range(3):
    r = rig.job(ups[k], "en", lyric_lines(3), "pasted", {"translate": False, "gloss": False})
    js.append(r)
ok("three jobs are accepted (202) with queue_pos 0, 1, 2", [r.status_code for r in js] == [202, 202, 202] and [r.json().get("queue_pos") for r in js] == [0, 1, 2], [r.json() for r in js])
r4 = rig.job(ups[3], "en", lyric_lines(3), "pasted", {"translate": False, "gloss": False})
ok("the 4th job -> 429 queue_full", r4.status_code == 429 and r4.json().get("code") == "queue_full" and has_hangul(r4.json().get("error")), r4.json())
rdup = rig.job(ups[1], "en", lyric_lines(3), "pasted", {"translate": False, "gloss": False})
ok("the same upload while its job is queued/running -> 409 job_running", rdup.status_code == 409 and rdup.json().get("code") == "job_running", rdup.json())
sts = [rig.status(r.json()["job"]) for r in js]
ok("one job is running, the others are queued (with queue_pos)", [s["state"] for s in sts].count("running") == 1 and [s["state"] for s in sts].count("queued") == 2
   and all("queue_pos" in s for s in sts if s["state"] == "queued"), [s["state"] for s in sts])
rcq = rig.post("/song/jobs/cancel", {"job": js[2].json()["job"]})
ok("a queued job is cancelled at once and its folder removed without ever running", rcq.json() == {"ok": True, "state": "cancelled"} and not os.path.exists(os.path.join(rig.root, js[2].json()["job"])))
r4b = rig.job(ups[3], "en", lyric_lines(3), "pasted", {"translate": False, "gloss": False})
ok("...and that frees a place in the queue", r4b.status_code == 202, r4b.json())
cancel_all(rig)

print("== K5-9 release and TTL ==")
rig = Rig(tag="rel", delay=0.0)
uid, r = rig.upload(small_b, "a.mp3")
jid = rig.job(uid, "en", lyric_lines(3), "pasted", {"translate": False, "gloss": False}).json()["job"]
rig.wait(jid)
ok("before release both folders exist", os.path.isdir(os.path.join(rig.root, jid)) and os.path.isdir(os.path.join(rig.root, "u_" + uid)))
rrel = rig.post("/song/jobs/release", {"job": jid})
ok("release -> {ok true, removed true}", rrel.status_code == 200 and rrel.json() == {"ok": True, "removed": True}, rrel.json())
ok("K5-9: after release no folder is left in the job root", rig.listing() == [], rig.listing())
ok("K5-9: status after release -> 404 no_job; result and audio too", rig.get("/song/jobs/status", job=jid).status_code == 404 and rig.get("/song/jobs/status", job=jid).json().get("code") == "no_job"
   and rig.result(jid).status_code == 404 and rig.get("/song/audio", job=jid, part=0).status_code == 404)
ok("release twice -> still ok (removed false)", rig.post("/song/jobs/release", {"job": jid}).json() == {"ok": True, "removed": False})
ok("release of an unknown upload_id -> ok, removed false", rig.post("/song/jobs/release", {"upload_id": new_uid()}).json() == {"ok": True, "removed": False})
uid, r = rig.upload(small_b, "a.mp3")
ok("release by upload_id removes an upload that never had a job", rig.post("/song/jobs/release", {"upload_id": uid}).json() == {"ok": True, "removed": True} and rig.listing() == [])
rig = Rig(tag="rel2", delay=0.6)
uid, r = rig.upload(mid_b, "m.mp3")
jid = rig.job(uid, "en", lyric_lines(3), "pasted", {"translate": False, "gloss": False}).json()["job"]
time.sleep(0.2)
rrun = rig.post("/song/jobs/release", {"job": jid})
ok("release of a running job -> 409 job_running (cancel it first)", rrun.status_code == 409 and rrun.json().get("code") == "job_running", rrun.json())
cancel_all(rig)

rig = Rig(tag="ttl", ttl=1, delay=0.0)
ok("TTL hook is read (both TTLs = 1 s)", song._state["upload_ttl"] == 1.0 and song._state["job_ttl"] == 1.0)
uid_a, _ = rig.upload(small_b, "a.mp3")
uid_b2 = new_uid()
rig.post("/song/upload", {"upload_id": uid_b2, "index": 0, "total": 2, "name": "a.mp3", "data_b64": b64(small_b[:5000])})
ok("TTL: both folders exist right after the upload", os.path.isdir(os.path.join(rig.root, "u_" + uid_a)) and os.path.isdir(os.path.join(rig.root, "u_" + uid_b2)))
time.sleep(1.7)
rhealth = rig.get("/song/jobs/status", job="j_00000000")
ok("K5-9: with HOEHWA_SONG_TTL_SEC=1 the next request removes the old folders", rhealth.status_code == 404 and rig.listing() == [], rig.listing())
rig = Rig(tag="ttl2", ttl=1, delay=0.0)
uid_c, _ = rig.upload(small_b, "a.mp3")
jc = rig.job(uid_c, "en", lyric_lines(3), "pasted", {"translate": False, "gloss": False}).json()["job"]
rig.wait(jc)
time.sleep(1.7)
rig.get("/song/jobs/status", job="j_00000000")
ok("TTL: a finished job and its upload are removed after the TTL", rig.listing() == [] and rig.get("/song/jobs/status", job=jc).status_code == 404, rig.listing())
rig = Rig(tag="ttl3", ttl=1, delay=0.8)
uid_d, _ = rig.upload(mid_b, "m.mp3")
jd = rig.job(uid_d, "en", lyric_lines(3), "pasted", {"translate": False, "gloss": False}).json()["job"]
time.sleep(1.8)
rig.get("/song/jobs/status", job="j_00000000")
ok("TTL: a running job and its upload are never removed", os.path.isdir(os.path.join(rig.root, jd)) and os.path.isdir(os.path.join(rig.root, "u_" + uid_d)))
cancel_all(rig)

print("== restart: queued / running jobs become failed + server_restart ==")
rig = Rig(tag="restart", delay=0.0)
uid, r = rig.upload(small_b, "a.mp3")
jid_r = "j_" + os.urandom(4).hex()
os.makedirs(os.path.join(rig.root, jid_r))
for st_name in ("running", "queued"):
    with open(os.path.join(rig.root, jid_r, "job.json"), "w", encoding="utf-8") as f:
        json.dump({"id": jid_r, "upload_id": uid, "lang": "en", "state": st_name, "stage": "asr", "pct": 40, "warnings": [], "error": None,
                   "created": time.time(), "finished": None, "orig_name": "a.mp3", "audio_bytes": 1, "audio_sha256": "", "parts": 1}, f)
    song.init(root=rig.root, fake_asr=True, **rig.helpers)
    s = rig.status(jid_r)
    ok("a '%s' job found on disk after a restart -> failed + error.code server_restart (Korean message)" % st_name,
       s["state"] == "failed" and s["error"]["code"] == "server_restart" and has_hangul(s["error"]["message"]), s)
jnew = rig.job(uid, "en", lyric_lines(3), "pasted", {"translate": False, "gloss": False})
ok("the upload survived: the same upload_id can start a new job", jnew.status_code == 202, jnew.json())
rig.wait(jnew.json()["job"])
ok("a done job survives a restart (result and audio still served)", (song.init(root=rig.root, fake_asr=True, **rig.helpers), rig.result(jnew.json()["job"]).status_code)[1] == 200)
with open(os.path.join(rig.root, jid_r, "job.json"), "w") as f:
    f.write("{broken")
song.init(root=rig.root, fake_asr=True, **rig.helpers)
ok("a job folder whose job.json is broken is removed at start", not os.path.exists(os.path.join(rig.root, jid_r)))
os.makedirs(os.path.join(rig.root, "notmine"))
os.makedirs(os.path.join(rig.root, "u_" + "Z" * 32))
song.init(root=rig.root, fake_asr=True, ttl_sec=1, **rig.helpers)
time.sleep(1.5)
rig.get("/song/jobs/status", job="j_00000000")
ok("folders that are not ours (other names) are never touched, even by the TTL sweep", os.path.isdir(os.path.join(rig.root, "notmine")) and os.path.isdir(os.path.join(rig.root, "u_" + "Z" * 32)))

# ====================================================================================================================
print("== safe delete: links and junctions are removed, never followed ==")
rig = Rig(tag="safe", delay=0.0)
victim = os.path.join(TMP, "victim_a")
os.makedirs(victim)
open(os.path.join(victim, "sentinel.txt"), "w").write("keep me")
uid, r = rig.upload(small_b, "a.mp3")
jid = rig.job(uid, "en", lyric_lines(3), "pasted", {"translate": False, "gloss": False}).json()["job"]
rig.wait(jid)
linked_up = make_link(os.path.join(rig.root, "u_" + uid, "evil_link"), victim)
linked_job = make_link(os.path.join(rig.root, jid, "evil_link2"), victim)
if linked_up and linked_job:
    ok("test setup (negative control): through the links inside the folders the outside file IS reachable - a delete that followed links would destroy it",
       os.path.exists(os.path.join(rig.root, "u_" + uid, "evil_link", "sentinel.txt")) and os.path.exists(os.path.join(rig.root, jid, "evil_link2", "sentinel.txt")))
    rrel = rig.post("/song/jobs/release", {"job": jid})
    ok("release with links inside: both folders are gone", rrel.json().get("removed") is True and rig.listing() == [], rig.listing())
    ok("release with links inside: the outside folder and its file are untouched", os.path.exists(os.path.join(victim, "sentinel.txt")) and open(os.path.join(victim, "sentinel.txt")).read() == "keep me")
else:
    skip("links inside job folders", "cannot create junctions or symlinks here")
# a link at the folder's own place
victim2 = os.path.join(TMP, "victim_b")
os.makedirs(os.path.join(victim2, "deep"))
open(os.path.join(victim2, "deep", "keep.txt"), "w").write("keep")
fake_job = os.path.join(rig.root, "j_" + os.urandom(4).hex())
if make_link(fake_job, victim2):
    ok("_rm_dir on a link that stands where a job folder would be: removes the link only", song._rm_dir(fake_job) is True and not os.path.lexists(fake_job)
       and os.path.exists(os.path.join(victim2, "deep", "keep.txt")))
else:
    skip("link at the folder place", "cannot create junctions or symlinks here")
fake_up = os.path.join(rig.root, "u_" + os.urandom(16).hex())
if make_link(fake_up, victim2):
    uid_l = os.path.basename(fake_up)[2:]
    r = rig.post("/song/upload", {"upload_id": uid_l, "index": 0, "total": 1, "name": "a.mp3", "data_b64": b64(small_b)})
    ok("an upload whose id is already a junction: the junction is replaced by a real folder, the target keeps all its files",
       r.status_code == 200 and not song._is_link(fake_up) and os.path.exists(os.path.join(victim2, "deep", "keep.txt")), r.json())
    rig.post("/song/jobs/release", {"upload_id": uid_l})
else:
    skip("upload id that is already a link", "cannot create junctions or symlinks here")
outside = os.path.join(TMP, "outside_u_" + "a" * 32)
os.makedirs(outside)
open(os.path.join(outside, "k.txt"), "w").write("x")
ok("_rm_dir refuses a folder outside the job root even when the name fits", song._rm_dir(outside) is False and os.path.exists(os.path.join(outside, "k.txt")))
os.makedirs(os.path.join(TMP, "j_" + "0" * 8))
ok("_rm_dir refuses j_xxxxxxxx outside the job root", song._rm_dir(os.path.join(TMP, "j_" + "0" * 8)) is False and os.path.isdir(os.path.join(TMP, "j_" + "0" * 8)))
os.makedirs(os.path.join(rig.root, "plain_name"))
ok("_rm_dir refuses a name that is not u_<32 hex> / j_<8 hex> (inside the root)", song._rm_dir(os.path.join(rig.root, "plain_name")) is False and os.path.isdir(os.path.join(rig.root, "plain_name")))
ok("_rm_dir refuses the root itself and a path with ..", song._rm_dir(rig.root) is False and song._rm_dir(os.path.join(rig.root, "..", os.path.basename(outside))) is False and os.path.isdir(outside))
sw = os.path.join(rig.root, "u_" + os.urandom(16).hex())
os.makedirs(sw)
if make_link(os.path.join(sw, "ln"), victim):
    song._write_json(os.path.join(sw, "meta.json"), {"id": os.path.basename(sw)[2:], "done": True, "touched": time.time() - 10 ** 6, "created": time.time() - 10 ** 6})
    song.init(root=rig.root, fake_asr=True, ttl_sec=1, **rig.helpers)
    ok("TTL sweep of an old upload that holds a junction: folder removed, outside file kept", not os.path.exists(sw) and os.path.exists(os.path.join(victim, "sentinel.txt")))
else:
    skip("TTL sweep with a junction inside", "cannot create junctions or symlinks here")


# ====================================================================================================================
print("== concurrency: /stt and /score keep working while a job runs ==")
lock = threading.Lock()
rig = Rig(tag="conc", delay=0.4, extra={"run_lock": lock})
uid, r = rig.upload(mid_b, "m.mp3")
jid = rig.job(uid, "en", lyric_lines(5), "pasted", {"translate": False, "gloss": False}).json()["job"]
t0 = time.time()
while time.time() - t0 < 10 and rig.status(jid)["stage"] != "asr":
    time.sleep(0.02)
waits, served = [], 0
tend = time.time() + 1.8
while time.time() < tend and rig.status(jid)["state"] == "running":
    a = time.time()
    got = lock.acquire(timeout=5)
    waits.append(time.time() - a)
    if got:
        served += 1                        # a /stt or /score request would run its model call here
        time.sleep(0.02)
        lock.release()
    time.sleep(0.03)
ok("while windows run, another request gets the model lock within about one window (max wait %.2f s of 0.4 s windows)" % max(waits), served >= 3 and max(waits) <= 1.2, (served, max(waits)))
st, _ = rig.wait(jid, timeout=30)
ok("...and the job still finishes (no deadlock)", st["state"] == "done", st)
ok("the lock is free after the job", lock.acquire(timeout=0.5) and (lock.release() or True))
# a request that holds the lock for a while (a long /score) delays one window, not the whole job
uid, r = rig.upload(mid_b, "m.mp3")
lock.acquire()
jid = rig.job(uid, "en", lyric_lines(5), "pasted", {"translate": False, "gloss": False}).json()["job"]
time.sleep(0.6)
s_mid = rig.status(jid)
lock.release()
st, _ = rig.wait(jid, timeout=30)
ok("a request holding the lock first: the job waits (stage asr, not failed), then runs to done", s_mid["state"] == "running" and st["state"] == "done", (s_mid, st))
# the lock is NOT held while the job does other work (a slow LLM call in the enrich stage)
slow_started = threading.Event()
slow_release = threading.Event()
helpers2 = song.fake_helpers()
orig_llm = helpers2["ollama_json"]


def slow_llm(*a, **k):
    slow_started.set()
    slow_release.wait(10)
    return orig_llm(*a, **k)


rig = Rig(tag="conc2", delay=0.0, extra={"run_lock": lock, "ollama_json": slow_llm})
uid, r = rig.upload(small_b, "a.mp3")
jid = rig.job(uid, "en", lyric_lines(3), "pasted", {"translate": True, "gloss": False, "ai_ok": True}).json()["job"]
ok("the job reaches the (slow) AI call", slow_started.wait(10))
got = lock.acquire(timeout=0.5)
ok("during the enrich stage the model lock is free (a /score would run at once)", got and rig.status(jid)["stage"] == "enrich", rig.status(jid))
if got:
    lock.release()
rc = rig.post("/song/jobs/cancel", {"job": jid})
slow_release.set()
settle()
ok("cancel during a running AI call: state cancelled, result is dropped, folder gone", rig.status(jid)["state"] == "cancelled" and not os.path.exists(os.path.join(rig.root, jid)), rig.status(jid))

print("== real transcribe_song path with a scripted model (not the fake): device decides the window, failures map to error codes ==")
class ScriptModel:
    def __init__(self, fail=None):
        self.calls = 0
        self.fail = fail

    def transcribe(self, chunk, **kw):
        self.calls += 1
        if self.fail:
            raise self.fail
        w = [SimpleNamespace(word=" hello", start=0.5, end=0.9, probability=0.9), SimpleNamespace(word=" world", start=1.0, end=1.5, probability=0.9)]
        return iter([SimpleNamespace(text="hello world", words=w, no_speech_prob=0.0)]), None


sm = ScriptModel()
rig = Rig(tag="real", fake=False, extra={"get_model": lambda: sm, "stt_info": {"device": "cpu", "compute_type": "int8"}, "run_lock": threading.Lock()})
uid, r = rig.upload(mid_b, "m.mp3")
jid = rig.job(uid, "en", [{"text": "hello world", "t": None, "p": 0}], "pasted", {"translate": False, "gloss": False}).json()["job"]
st, _ = rig.wait(jid)
ok("injected model: the job is done and Whisper was called once per 20 s window of a 100 s song (CPU window)", st["state"] == "done" and 4 <= sm.calls <= 6, (st, sm.calls))
sm2 = ScriptModel()
rig = Rig(tag="real2", fake=False, extra={"get_model": lambda: sm2, "stt_info": {"device": "cuda"}, "run_lock": threading.Lock()})
uid, r = rig.upload(mid_b, "m.mp3")
jid = rig.job(uid, "en", None, options={"translate": False, "gloss": False}).json()["job"]
rig.wait(jid)
ok("CUDA device -> 30 s windows (100 s song = 4 calls)", 3 <= sm2.calls <= 4, sm2.calls)
rig = Rig(tag="real3", fake=False, extra={"get_model": lambda: (_ for _ in ()).throw(RuntimeError("no model")), "stt_info": {}, "run_lock": threading.Lock()})
uid, r = rig.upload(small_b, "a.mp3")
jid = rig.job(uid, "en", lyric_lines(2), "pasted", {"translate": False, "gloss": False}).json()["job"]
st, _ = rig.wait(jid)
ok("model cannot be loaded -> failed + model_missing (Korean), the upload stays", st["state"] == "failed" and st["error"]["code"] == "model_missing" and has_hangul(st["error"]["message"])
   and os.path.isdir(os.path.join(rig.root, "u_" + uid)), st)
rig = Rig(tag="real4", fake=False, extra={"get_model": lambda: ScriptModel(fail=RuntimeError("cuda exploded")), "stt_info": {"device": "cpu"}, "run_lock": threading.Lock()})
uid, r = rig.upload(small_b, "a.mp3")
jid = rig.job(uid, "en", lyric_lines(2), "pasted", {"translate": False, "gloss": False}).json()["job"]
st, _ = rig.wait(jid)
ok("the model raises while transcribing -> failed + asr_failed, and the lock is free", st["state"] == "failed" and st["error"]["code"] == "asr_failed", st)
rig = Rig(tag="real5", fake=False, extra={"get_model": lambda: ScriptModel(), "stt_info": {"device": "cpu"}, "run_lock": threading.Lock()})
uid, r = rig.upload(silent_b, "silent.mp3")
jid = rig.job(uid, "en", None, options={"translate": False, "gloss": False}).json()["job"]
st, _ = rig.wait(jid)
ok("a completely silent file without lyrics -> failed + no_speech", st["state"] == "failed" and st["error"]["code"] == "no_speech" and has_hangul(st["error"]["message"]), st)
uid, r = rig.upload(silent_b, "silent.mp3")
jid = rig.job(uid, "en", lyric_lines(3), "pasted", {"translate": False, "gloss": False}).json()["job"]
st, _ = rig.wait(jid)
sj = rig.result(jid).json() if st["state"] == "done" else {}
ok("a silent file WITH lyrics still gives a song (estimated times, no_vocals + low_match warnings)", st["state"] == "done" and "no_vocals" in sj.get("warnings", []) and "low_match" in sj.get("warnings", [])
   and all(l["est"] or all(w["est"] for w in l["words"]) for l in sj["lines"]), sj.get("warnings"))
rig = Rig(tag="real6", fake=False, extra={"get_model": lambda: ScriptModel(), "stt_info": {"device": "cpu"}, "run_lock": threading.Lock()})
uid, r = rig.upload(small_b, "a.mp3")
jid = rig.job(uid, "en", lyric_lines(2), "pasted", {"translate": False, "gloss": False}).json()["job"]
rig.wait(jid)
sj = rig.result(jid).json()
ok("lyrics unrelated to what was heard: low_match and est_times (F6)", "low_match" in sj["warnings"] and "est_times" in sj["warnings"], sj["warnings"])

print("== storage ==")
rig = Rig(tag="store", delay=0.0)
song.FOLDER_MAX = 50000
r = rig.post("/song/upload", {"upload_id": new_uid(), "index": 0, "total": 1, "name": "a.mp3", "data_b64": b64(small_b)})
song.FOLDER_MAX = 1024 * 1024 * 1024
ok("a folder over FOLDER_MAX -> 503 storage_full (Korean) and nothing is left", r.status_code == 503 and r.json().get("code") == "storage_full" and has_hangul(r.json().get("error")) and rig.listing() == [], (r.json(), rig.listing()))
real_free = song._disk_free
song._disk_free = lambda: 100
r = rig.post("/song/upload", {"upload_id": new_uid(), "index": 0, "total": 1, "name": "a.mp3", "data_b64": b64(small_b)})
song._disk_free = real_free
ok("less than 1 GiB free on the disk -> 503 storage_full", r.status_code == 503 and r.json().get("code") == "storage_full", r.json())
real_need = song._need_av
song._need_av = lambda: song._fail(503, "song_unavailable")
r = rig.post("/song/upload", {"upload_id": new_uid(), "index": 0, "total": 1, "name": "a.mp3", "data_b64": b64(small_b)})
song._need_av = real_need
ok("no PyAV -> 503 song_unavailable", r.status_code == 503 and r.json().get("code") == "song_unavailable", r.json())

# ====================================================================================================================
print("== POST /song/enrich ==")
rig = Rig(tag="enr", delay=0.0)
body = {"lang": "en", "lines": [{"i": 3, "text": "The %s river runs wide" % MARK}, {"i": 4, "text": "Beautiful memories remain"}], "tasks": ["reading", "tokens", "translate", "gloss"], "known": [], "ai_ok": True}
r = rig.post("/song/enrich", body)
d = r.json()
ok("enrich: 200 with lines / glossary / warnings; i kept", r.status_code == 200 and [l["i"] for l in d["lines"]] == [3, 4] and "glossary" in d and "warnings" in d, d)
ok("enrich: each line has reading pron ko words (tokens with lemma level zipf content)", all({"reading", "pron", "ko", "words"} <= set(l) for l in d["lines"]) and {"w", "lemma", "level", "zipf", "content"} <= set(d["lines"][0]["words"][0]))
ok("enrich: ai_ok true -> Korean translation", all(has_hangul(l["ko"]) for l in d["lines"]), d["lines"])
rig.helpers["llm_calls"].clear()
body["ai_ok"] = False
r = rig.post("/song/enrich", body)
d = r.json()
ok("enrich: ai_ok false -> no AI call at all, ko '' + ko_missing + gloss_missing, tokens still there", rig.helpers["llm_calls"] == [] and all(l["ko"] == "" for l in d["lines"]) and "ko_missing" in d["warnings"]
   and "gloss_missing" in d["warnings"] and d["lines"][0]["words"], d)
del body["ai_ok"]
rig.helpers["llm_calls"].clear()
d = rig.post("/song/enrich", body).json()
ok("enrich: ai_ok missing = false", rig.helpers["llm_calls"] == [] and d["lines"][0]["ko"] == "")
r = rig.post("/song/enrich", {"lang": "en", "lines": [{"i": k, "text": "line %d" % k} for k in range(20)], "tasks": ["reading"]})
ok("enrich: exactly 20 lines are fine", r.status_code == 200 and len(r.json()["lines"]) == 20)
r = rig.post("/song/enrich", {"lang": "en", "lines": [{"i": k, "text": "line %d" % k} for k in range(21)], "tasks": ["reading"]})
ok("enrich: 21 lines -> 400 bad_request", r.status_code == 400 and r.json().get("code") == "bad_request" and has_hangul(r.json().get("error")), r.json())
for bad_body, label in (({"lang": "fr", "lines": [{"i": 0, "text": "a"}], "tasks": ["reading"]}, "lang fr"), ({"lang": "en", "lines": [], "tasks": ["reading"]}, "no lines"),
                        ({"lang": "en", "lines": [{"i": 0, "text": "a"}], "tasks": ["evil"]}, "unknown task"), ({"lang": "en", "lines": [{"i": 0, "text": "a"}], "tasks": []}, "empty tasks"),
                        ({"lang": "en", "lines": [{"i": "x", "text": "a"}], "tasks": ["reading"]}, "i is a string"), ({"lang": "en", "lines": [{"i": 0, "text": 5}], "tasks": ["reading"]}, "text is a number"),
                        ({"lang": "en", "lines": [{"i": 0, "text": "a"}], "tasks": ["reading"], "ai_ok": "yes"}, "ai_ok is a string"),
                        ({"lang": "en", "lines": [{"i": 0, "text": "a"}], "tasks": ["reading"], "known": [1]}, "known holds a number")):
    r = rig.post("/song/enrich", bad_body)
    ok("enrich: bad request (%s) -> 400" % label, r.status_code == 400 and r.json().get("code") == "bad_request", (r.status_code, r.json()))
r = rig.post("/song/enrich", {"lang": "ja", "lines": [{"i": 0, "text": "きみがわらう"}], "tasks": ["reading", "tokens"]})
ok("enrich ja: reading hiragana, pron katakana", r.status_code == 200 and re.fullmatch(r"[ぁ-ゖー]+", r.json()["lines"][0]["reading"]) and re.fullmatch(r"[ァ-ヺー]+", r.json()["lines"][0]["pron"]), r.json())
r = rig.post("/song/enrich", {"lang": "en", "lines": [{"i": 0, "text": "z" * 500}], "tasks": ["reading"]})
ok("enrich: a very long line is cut to 200 characters inside, request still fine", r.status_code == 200)
real_to = song.ENRICH_TIMEOUT
song.ENRICH_TIMEOUT = 0.6
helpers3 = song.fake_helpers()
oj3 = helpers3["ollama_json"]
slow_gate = threading.Event()


def slow2(*a, **k):
    slow_gate.wait(3)
    return oj3(*a, **k)


rig = Rig(tag="enr2", delay=0.0, extra={"ollama_json": slow2})
t0 = time.time()
r = rig.post("/song/enrich", {"lang": "en", "lines": [{"i": 0, "text": "slow line"}], "tasks": ["translate"], "ai_ok": True})
dt = time.time() - t0
ok("enrich timeout (hook: 0.6 s instead of 60 s) -> 504 enrich_timeout in about that time (%.2f s)" % dt, r.status_code == 504 and r.json().get("code") == "enrich_timeout" and 0.5 <= dt <= 2.0 and has_hangul(r.json().get("error")), (r.status_code, r.json()))
slow_gate.set()
time.sleep(0.5)
song.ENRICH_TIMEOUT = real_to
r = rig.post("/song/enrich", {"lang": "en", "lines": [{"i": 0, "text": "fast line"}], "tasks": ["reading"]})
ok("after a timeout the worker slot is freed again (the next request works)", r.status_code == 200, r.json())
ok("source constant ENRICH_TIMEOUT is 60 and ENRICH_MAX_LINES is 20", real_to == 60.0 and song.ENRICH_MAX_LINES == 20)
rig.helpers["llm_calls"].clear()
res_conc = []
rig3 = Rig(tag="enr3", delay=0.0, extra={"ollama_json": slow2})
slow_gate.clear()


def one():
    res_conc.append(rig3.post("/song/enrich", {"lang": "en", "lines": [{"i": 0, "text": "x line"}], "tasks": ["translate"], "ai_ok": True}).status_code)


song.ENRICH_TIMEOUT = 2.5
thr = [threading.Thread(target=one) for _ in range(4)]
for t in thr:
    t.start()
time.sleep(0.6)
slow_gate.set()
for t in thr:
    t.join(10)
song.ENRICH_TIMEOUT = real_to
ok("more than 2 enrich requests at once: the extra ones get 429 queue_full (no pile-up of LLM calls)", sorted(res_conc).count(200) >= 2 and 429 in res_conc, res_conc)

# ====================================================================================================================
print("== K5-11 LAN gate (in-process: the real LanGate around the app, requests from a Tailscale-like source) ==")
import lan  # noqa: E402
rig = Rig(tag="lan", delay=0.0)
gate_app = FastAPI()
gate_app.include_router(song.router)
dev_file = os.path.join(TMP, "lan_devices_test.json")
lan_cfg = {"lan": dict(lan.DEFAULT_LAN)}
lan.attach(gate_app, lan_cfg, lambda c: None, LOG, TMP, tag="k5", devices_file=dev_file, persist=False, auto_start=False)
token = "hp1_" + base64.urlsafe_b64encode(os.urandom(32)).rstrip(b"=").decode("ascii")
lan.S.devices.append({"id": "k5dev001", "name": "test phone", "token_sha256": hashlib.sha256(token.encode("ascii")).hexdigest(), "created": "2026-01-01T00:00:00+00:00",
                      "last_seen": "2026-01-01T00:00:00+00:00", "last_ip": ""})
gate = lan.LanGate(gate_app)
NINE = [("POST", "/song/upload"), ("GET", "/song/upload"), ("POST", "/song/jobs"), ("GET", "/song/jobs/status"), ("POST", "/song/jobs/cancel"), ("GET", "/song/result"),
        ("GET", "/song/audio"), ("POST", "/song/jobs/release"), ("POST", "/song/enrich")]
ok("lan.ALLOW has exactly these nine /song routes (and no other /song path)", {k for k in lan.ALLOW if k[1].startswith("/song")} == set(NINE) and len(lan.ALLOW) == 34)


async def gate_calls():
    out = {}
    transport = httpx.ASGITransport(app=gate, client=("127.0.0.1", 5555))
    async with httpx.AsyncClient(transport=transport, base_url="http://100.64.0.1:8775") as cl:
        for m, p in NINE:
            q = "?job=j_00000000" if p in ("/song/jobs/status", "/song/result", "/song/audio") else ("?upload_id=" + "a" * 32 if (m, p) == ("GET", "/song/upload") else "")
            out[("notoken", m, p)] = (await cl.request(m, p + q, json={} if m == "POST" else None)).status_code, None
            r = await cl.request(m, p + q, json={} if m == "POST" else None, headers={"Authorization": "Bearer " + token})
            out[("token", m, p)] = r.status_code, r.json()
        r = await cl.get("/song/jobs/status?job=j_00000000")
        out["notoken_body"] = r.status_code, r.json()
        r = await cl.post("/song/purge", json={}, headers={"Authorization": "Bearer " + token})
        out["purge"] = r.status_code, r.json()
        r = await cl.get("/song/jobs", headers={"Authorization": "Bearer " + token})
        out["jobs_get"] = r.status_code, r.json()
        r = await cl.get("/song/jobs/status?job=j_00000000", headers={"Authorization": "Bearer hp1_" + "A" * 43})
        out["badtoken"] = r.status_code, r.json()
    return out


gc = asyncio.run(gate_calls())
ok("no token on /song/jobs/status -> 401 token_missing (Korean)", gc["notoken_body"][0] == 401 and gc["notoken_body"][1].get("code") == "token_missing" and has_hangul(gc["notoken_body"][1].get("error")), gc["notoken_body"])
ok("no token on every one of the nine paths -> 401", all(gc[("notoken", m, p)][0] == 401 for m, p in NINE), {k: v[0] for k, v in gc.items() if isinstance(k, tuple) and k[0] == "notoken"})
ok("with the token every one of the nine paths reaches song.py (200/202/400/404/409 - never 401/403)",
   all(gc[("token", m, p)][0] in (200, 202, 400, 404, 409) and gc[("token", m, p)][1].get("code") not in ("lan_forbidden", "token_missing", "token_invalid") for m, p in NINE),
   {(m, p): gc[("token", m, p)] for m, p in NINE})
ok("a /song path that is not in the list (POST /song/purge) -> 403 lan_forbidden", gc["purge"][0] == 403 and gc["purge"][1].get("code") == "lan_forbidden", gc["purge"])
ok("GET /song/jobs (not listed, only POST is) -> 403 lan_forbidden", gc["jobs_get"][0] == 403 and gc["jobs_get"][1].get("code") == "lan_forbidden", gc["jobs_get"])
ok("a wrong token -> 401 token_invalid", gc["badtoken"][0] == 401 and gc["badtoken"][1].get("code") == "token_invalid", gc["badtoken"])


async def gate_upload():
    transport = httpx.ASGITransport(app=gate, client=("127.0.0.1", 5555))
    async with httpx.AsyncClient(transport=transport, base_url="http://100.64.0.1:8775") as cl:
        h = {"Authorization": "Bearer " + token}
        u = new_uid()
        r = await cl.post("/song/upload", json={"upload_id": u, "index": 0, "total": 1, "name": "a.mp3", "data_b64": b64(small_b)}, headers=h)
        j = await cl.post("/song/jobs", json={"upload_id": u, "lang": "en", "lyrics": {"source": "pasted", "lines": lyric_lines(3)}, "options": {"translate": False, "gloss": False}}, headers=h)
        jid_ = j.json().get("job")
        for _ in range(100):
            s = (await cl.get("/song/jobs/status?job=" + jid_, headers=h)).json()
            if s["state"] in ("done", "failed"):
                break
            await asyncio.sleep(0.05)
        res_ = await cl.get("/song/result?job=" + jid_, headers=h)
        au = await cl.get("/song/audio?job=%s&part=0" % jid_, headers=h)
        rel = await cl.post("/song/jobs/release", json={"job": jid_}, headers=h)
        return r.status_code, j.status_code, s["state"], res_.status_code, au.status_code, rel.json()


gu = asyncio.run(gate_upload())
ok("a whole upload -> job -> result -> audio -> release goes through the LAN gate with the token", gu[:5] == (200, 202, "done", 200, 200) and gu[5].get("removed") is True, gu)

# ====================================================================================================================
print("== K5-13 no lyrics / titles / audio in logs or on disk (except the result itself) ==")
logtext = LOGBUF.getvalue()
ok("the log of this whole run never contains the lyric marker %s (any case)" % MARK, MARK.lower() not in logtext.lower())
ok("the log never contains the title marker or the ZZ strings", TMARK not in logtext and "THIS MUST NOT APPEAR" not in logtext)
ok("the log is not empty (the capture works: it has song: lines)", "song: job" in logtext and len(logtext) > 500, len(logtext))
ok("checker self-test: a log line that does contain the marker IS found by the same search (the capture works)", (lambda: (LOG.info("probe %s", MARK), MARK.lower() in LOGBUF.getvalue().lower())[1])())
LOGBUF.seek(0)
LOGBUF.truncate()
rig = Rig(tag="priv", delay=0.0)
uid, r = rig.upload(small_b, "a.mp3")
jid = rig.job(uid, "en", [{"text": MARK + " la la", "t": None, "p": 0}, {"text": "other " + MARK, "t": None, "p": 0}], "pasted", {"translate": True, "gloss": True, "ai_ok": True}, title=TMARK).json()["job"]
stp, _ = rig.wait(jid)
disk_hits = []
for dp, dn, fn in os.walk(rig.root):
    for n in fn:
        if n in ("song.json",):
            continue
        try:
            data = open(os.path.join(dp, n), "rb").read()
        except OSError:
            continue
        if MARK.encode() in data or TMARK.encode() in data:
            disk_hits.append(n)
ok("job.json and meta.json hold no lyrics or title (only song.json, the result, does)", disk_hits == [], disk_hits)
ok("the status answers hold no lyrics or title", MARK not in json.dumps(stp) and TMARK not in json.dumps(stp))
ok("the result does hold them (that is its job)", MARK in rig.result(jid).text)
rig.post("/song/jobs/release", {"job": jid})
ok("after release nothing of the song is on disk", rig.listing() == [])
joblog = LOGBUF.getvalue()
ok("still no marker in the log after the privacy job (translate + gloss on)", MARK.lower() not in joblog.lower() and TMARK.lower() not in joblog.lower())
src_lines = [l for l in src.splitlines() if re.search(r"_log\(\)\.(info|warning|error|exception|debug)", l)]
ok("every log call in song.py logs counts / ids / state names only (no 'text', 'title', 'lyric', 'lines[' variable in a log argument)",
   not [l for l in src_lines if re.search(r"\btext\b|\btitle\b|\bartist\b|\bnorm\b|\bitems\[|lines\[", l)], [l for l in src_lines if re.search(r"\btext\b|\btitle\b|\bartist\b", l)])
ok("song.py never calls log.exception (tracebacks may carry request text)", "exception(" not in "\n".join(src_lines) and ".exception(" not in src)

# ====================================================================================================================
print("== wiring (source) ==")
srv = open(os.path.join(HERE, "server.py"), encoding="utf-8").read()
ok("server.py: import song, song.init(...), include_router(song.router), /health song + song_v", "import song" in srv and re.search(r"song\.init\(log=log", srv) and "app.include_router(song.router)" in srv
   and '"song": song.available(), "song_v": song.SONG_V' in srv)
ok("server.py wires get_stt and the SAME _stt_run_lock object (not a new lock)", "get_model=get_stt, run_lock=_stt_run_lock" in srv)
ok("song.py itself never imports server / reading / faster_whisper at module level", not re.search(r"^(import|from)\s+(server|reading|faster_whisper|torch)\b", src, re.M))
ok("song.py never takes the model lock itself (it is only handed to transcribe_song, which takes it per window)", not re.search(r"^\s*with\s+(lock|H\[|.*run_lock)", src, re.M) and "_stt_run_lock" not in re.sub(r'"""[\s\S]*?"""', "", src))
ok("the phone link has no auth code of its own in song.py", "Authorization" not in src and "hp1_" not in src and "bearer" not in src.lower())
stub_src = open(os.path.join(HERE, "lan_stub_server.py"), encoding="utf-8").read()
ok("lan_stub_server.py has --song (fake Whisper) and refuses it without the test hooks", '"--song"' in stub_src and "--song needs the test hooks" in stub_src)
health_ok = (lambda: rig.c.get("/health").status_code)()
ok("/health is not a song.py route (server.py owns it)", health_ok == 404)
ok("available() is true here (PyAV + numpy are installed)", song.available() is True)

# ====================================================================================================================
if arg("--stub"):
    port = int(arg("--stub"))
    print("== stub server over real HTTP (port %d) ==" % port)
    s_ = socket.socket()
    free = s_.connect_ex(("127.0.0.1", port)) != 0
    s_.close()
    if not free:
        skip("stub run", "port %d is not free" % port)
    else:
        sdir = os.path.join(TMP, "stub_jobs")
        env = dict(os.environ, HOEHWA_TEST_HOOKS="1")
        proc = subprocess.Popen([sys.executable, "-I", os.path.join(HERE, "lan_stub_server.py"), "--port", str(port), "--tag", "k5stub", "--devices-file",
                                 os.path.join(TMP, "stub_dev.json"), "--song", "--song-dir", sdir, "--song-delay", "0.05"],
                                stdout=open(os.path.join(TMP, "stub.out"), "wb"), stderr=subprocess.STDOUT, cwd=HERE, env=env)
        try:
            base = "http://127.0.0.1:%d" % port
            t0 = time.time()
            up = False
            while time.time() - t0 < 30:
                try:
                    if httpx.get(base + "/health", timeout=1).status_code == 200:
                        up = True
                        break
                except Exception:
                    time.sleep(0.2)
            ok("stub --song is up", up)
            if up:
                h = httpx.get(base + "/health").json()
                ok("stub /health: song true, song_v 1", h.get("song") is True and h.get("song_v") == 1, h)
                hdr = {"content-type": "application/json"}
                u = new_uid()
                r = httpx.post(base + "/song/upload", json={"upload_id": u, "index": 0, "total": 1, "name": "a.mp3", "data_b64": b64(small_b)}, headers=hdr, timeout=30)
                ok("stub: upload over HTTP", r.status_code == 200 and r.json().get("done"), r.text[:200])
                j = httpx.post(base + "/song/jobs", json={"upload_id": u, "lang": "en", "lyrics": {"source": "pasted", "lines": lyric_lines(4)}, "options": {"ai_ok": True}}, headers=hdr)
                jid_ = j.json().get("job")
                for _ in range(100):
                    s = httpx.get(base + "/song/jobs/status", params={"job": jid_}).json()
                    if s["state"] in ("done", "failed"):
                        break
                    time.sleep(0.1)
                res_ = httpx.get(base + "/song/result", params={"job": jid_})
                ok("stub: job done and a result with lines", s["state"] == "done" and res_.status_code == 200 and len(res_.json()["lines"]) == 4, s)
                rel = httpx.post(base + "/song/jobs/release", json={"job": jid_}, headers=hdr)
                ok("stub: release removes the folders", rel.json().get("removed") is True and os.listdir(sdir) == [], os.listdir(sdir))
        finally:
            proc.terminate()
            try:
                proc.wait(10)
            except Exception:
                proc.kill()
        ok("stub process was ended", proc.poll() is not None)

# ====================================================================================================================
if arg("--base"):
    base = arg("--base").rstrip("/")
    sf = arg("--song-file")
    print("== live server %s (real models) ==" % base)
    if "8770" in base or "8775" in base or "8776" in base:
        sys.exit("refusing the app's real ports")
    hdr = {"content-type": "application/json"}
    h = httpx.get(base + "/health", timeout=10).json()
    ok("live /health: song true and song_v 1", h.get("song") is True and h.get("song_v") == 1, {k: h.get(k) for k in ("song", "song_v", "stt")})
    if not sf or not os.path.exists(sf):
        skip("live job", "give --song-file")
    else:
        data = open(sf, "rb").read()
        u = new_uid()
        total = -(-len(data) // (3 * MiB))
        for i in range(total):
            r = httpx.post(base + "/song/upload", json={"upload_id": u, "index": i, "total": total, "name": os.path.basename(sf), "data_b64": b64(data[i * 3 * MiB:(i + 1) * 3 * MiB])}, headers=hdr, timeout=60)
        up = r.json()
        ok("live upload done with a duration", r.status_code == 200 and up.get("done") and up.get("duration", 0) > 5, up)
        lj = arg("--lyrics-json")
        lines_live = None
        lang = "en"
        if lj and os.path.exists(lj):
            tr = json.load(open(lj, encoding="utf-8"))
            lang = tr.get("lang", "en")
            lines_live = [{"text": l["text"], "t": None, "p": l.get("p", 0)} for l in tr["lines"]]
        body = {"upload_id": u, "lang": lang, "title": "live", "options": {"translate": False, "gloss": False, "ai_ok": False}}
        if lines_live:
            body["lyrics"] = {"source": "pasted", "lines": lines_live}
        j = httpx.post(base + "/song/jobs", json=body, headers=hdr)
        jid_ = j.json().get("job")
        ok("live job accepted", j.status_code == 202, j.text[:200])
        # while the job runs: /stt (needs the model lock) and /health must keep answering
        quiet = (np.random.RandomState(3).randn(16000 * 2) * 0.02).astype(np.float32)
        import soundfile as sf_
        bio = io.BytesIO()
        sf_.write(bio, quiet, 16000, format="WAV", subtype="PCM_16")
        stt_times, stt_codes = [], []
        pcts = []
        t_job = time.time()
        while time.time() - t_job < 600:
            s = httpx.get(base + "/song/jobs/status", params={"job": jid_}, timeout=10).json()
            pcts.append(s["pct"])
            if s["state"] in ("done", "failed", "cancelled"):
                break
            a = time.time()
            try:
                rr = httpx.post(base + "/stt", json={"lang": lang, "audio_b64": b64(bio.getvalue())}, headers=hdr, timeout=120)
                stt_codes.append(rr.status_code)
                stt_times.append(time.time() - a)
            except Exception as e:
                stt_codes.append(type(e).__name__)
            time.sleep(0.3)
        ok("live: the job is done (real Whisper), pct reached 100 and never went down", s["state"] == "done" and s["pct"] == 100 and pcts == sorted(pcts), s)
        ok("live: /stt answered 200 while the job ran (%d calls, slowest %.1f s)" % (len(stt_codes), max(stt_times or [0])), stt_codes and all(c == 200 for c in stt_codes) and max(stt_times or [0]) < 60, stt_codes)
        res_ = httpx.get(base + "/song/result", params={"job": jid_}, timeout=30).json()
        ok("live: result has lines with word times inside the duration", len(res_["lines"]) >= 1 and song_align.check_lines(res_["lines"], res_["duration"]) == [], res_["warnings"])
        if lines_live:
            ok("live: lyrics given -> as many lines as lyrics, no low_match", len(res_["lines"]) == len(lines_live) and "low_match" not in res_["warnings"], res_["warnings"])
        ok("live: ai_ok false -> ko empty, ko_missing not required (translate off)", all(l["ko"] == "" for l in res_["lines"]))
        r2 = httpx.post(base + "/song/jobs/release", json={"job": jid_}, headers=hdr)
        ok("live: release", r2.json().get("removed") is True and httpx.get(base + "/song/jobs/status", params={"job": jid_}).status_code == 404)

# ====================================================================================================================
cancel_all(rig)
for lk in LINKS:
    if os.path.lexists(lk) and song._is_link(lk):
        song._rm_link(lk)
shutil.rmtree(TMP, ignore_errors=True)
n_pass, n_fail = len(PASSED), len(FAILED)
if SKIPPED:
    print("skipped (not counted as passed): %d -> %s" % (len(SKIPPED), "; ".join(SKIPPED)))
if n_fail:
    print("FAILED:")
    for name in FAILED:
        print("  -", name)
print("== test_song: %d passed, %d failed ==" % (n_pass, n_fail))
sys.exit(1 if n_fail else 0)
