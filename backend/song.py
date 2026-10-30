# -*- coding: utf-8 -*-
"""Song study K5: upload / job manager / result API for "learn from a song" (design docs/song_study_design.md 5.1, 3.6, 12.1b, 12.1c).

  POST /song/upload            one 3 MiB chunk of the music file (base64 JSON); the last chunk checks and normalises the file
  GET  /song/upload            next chunk to send (resume)
  POST /song/jobs              start a job (queue of at most QUEUE_MAX; one job runs at a time, thread "song-job")
  GET  /song/jobs/status       state / stage / pct / eta_sec / message_ko / warnings / error
  POST /song/jobs/cancel       cancel (state "cancelled" at once; the thread stops between two windows)
  GET  /song/result            the finished song JSON (design 5.2, without "id")
  GET  /song/audio             one chunk (<= 3 MiB) of the normalised MP3 as base64
  POST /song/jobs/release      delete the job and the upload folder now
  POST /song/enrich            reading / pron / translate / tokens / gloss for <= 20 edited lines (sync, 60 s)

Pipeline of a job:  decode -> (Japanese + lyrics: song_enrich tokens first) -> song_asr.transcribe_song (hint off, VAD off,
design 12.1c; the lock is server._stt_run_lock and is taken per window only) -> Japanese: contextual readings "k" -> song_align
(align_lyrics | lines_from_lrc + estimate_lrc_offset | lines_from_asr) -> song_enrich (optional AI: only when options.ai_ok).

Privacy: the server keeps music and lyrics only in song_jobs (backend/cache/song_jobs, git-ignored) while a job lives
(release = at once, otherwise 24 h / 2 h). Lyric text, the music, titles and artists are never written to the log (only ids, counts,
state names, error codes). Folders are only ever deleted by _rm_dir: a direct child of the job root with a fixed name pattern, and
links / junctions inside it are removed themselves, never followed.

server.py injects the helpers: song.init(log=, ApiError=, readmode=, ollama_json=, ko_ok=, ja_reading=, ja_pron=, ja_to_kata=,
get_model=server.get_stt, run_lock=server._stt_run_lock, stt_info=server._stt_info). The module has no authentication code: the phone
link (lan.py) gates /song/* per listener (ALLOW list) like every other route.

Test hooks (only with HOEHWA_TEST_HOOKS=1): HOEHWA_SONG_DIR (job root), HOEHWA_SONG_TTL_SEC (both TTLs), HOEHWA_SONG_FAKE_ASR=1 (a fake
Whisper that "hears" the lyrics, or numbered filler words without lyrics), HOEHWA_SONG_FAKE_ASR_DELAY (seconds per window, held inside the
model lock like a real window).
"""
import base64
import binascii
import hashlib
import json
import logging
import math
import os
import re
import secrets
import shutil
import stat
import threading
import time
import unicodedata
from concurrent.futures import ThreadPoolExecutor, TimeoutError as FutureTimeout
from types import SimpleNamespace

from fastapi import APIRouter, Request
from fastapi.responses import JSONResponse
from starlette.concurrency import run_in_threadpool

import song_align
import song_asr
import song_enrich

# ---- limits (design 5.1) ---------------------------------------------------------------------------------------------
SONG_V = 1
MAX_SONG_BYTES = 64 * 1024 * 1024
MAX_SONG_SEC = 600
CHUNK_BYTES = 3 * 1024 * 1024
MAX_LINES = 400
MAX_LINE_CHARS = 200
MAX_LYRIC_CHARS = 20000
QUEUE_MAX = 3
UPLOAD_TTL = 2 * 3600
JOB_TTL = 24 * 3600
FOLDER_MAX = 1024 * 1024 * 1024

# ---- other settings ---------------------------------------------------------------------------------------------------
MIN_SONG_SEC = 1.0                      # shorter is not a song (and random bytes that happen to decode a frame are rejected)
MAX_CHUNKS = 256                        # "total" of one upload
ENRICH_MAX_LINES = 20
ENRICH_TIMEOUT = 60.0
ENRICH_PARALLEL = 2
MAX_TEXT_FIELD = 200                    # title / artist
MAX_B64_CHARS = CHUNK_BYTES // 3 * 4 + 16
JSON_LIMIT = {"upload": 6 * 1024 * 1024, "other": 2 * 1024 * 1024}
NORM_BITRATE = 128000
NORM_RATE = 44100
PASS_MAX_BITRATE = 160000               # an MP3 already at most this big (44.1 kHz, <= stereo) is kept byte for byte
SAMPLE_SEC = 30.0                       # LRC "verify": three samples of this length at 20 / 50 / 80 % of the song
SAMPLE_POINTS = (0.2, 0.5, 0.8)
OFFSET_MIN_APPLY = 0.25                 # an estimated LRC offset below this is the estimator's own noise: not applied, no offset_guess
EXTS = ("mp3", "ogg", "wav", "m4a", "flac", "aac", "opus")
ALLOWED_WARNINGS = ("low_match", "no_vocals", "ko_missing", "gloss_missing", "est_times", "offset_guess", "duration_mismatch",
                    "hallucination_cut", "lyrics_truncated")
STAGES = ("decode", "separate", "asr", "align", "enrich", "package")
APP_VERSION = ""                        # set by init(app_version=...) (server.py leaves it empty)

_UP_RE = re.compile(r"^[0-9a-f]{32}$")
_JOB_RE = re.compile(r"^j_[0-9a-f]{8}$")
_UPDIR_RE = re.compile(r"^u_[0-9a-f]{32}$")
_CTRL = re.compile(r"[\x00-\x1f\x7f]")
_REPARSE = 0x400                        # FILE_ATTRIBUTE_REPARSE_POINT (junction / symlink on Windows)

MSG = {
    "bad_request": "요청 형식이 올바르지 않아요.",
    "bad_index": "조각 번호가 올바르지 않아요.",
    "no_upload": "올린 파일을 찾지 못했어요. 처음부터 다시 올려 주세요.",
    "no_job": "그런 작업이 없어요. 이미 지워졌거나 PC가 다시 시작됐을 수 있어요.",
    "upload_gap": "조각 순서가 맞지 않아요. 이어서 올려 주세요.",
    "job_running": "이 곡은 이미 처리하고 있어요.",
    "not_done": "아직 끝나지 않은 작업이에요.",
    "too_large": "파일이 너무 커요. 64MB 이하의 파일을 골라 주세요.",
    "too_long": "곡이 너무 길어요. 10분 이하의 곡을 골라 주세요.",
    "bad_audio": "이 파일의 소리를 읽을 수 없어요. 보호된 파일이거나 깨진 파일일 수 있어요. 다른 형식(mp3)으로 바꿔서 다시 시도해 주세요.",
    "queue_full": "처리 중인 곡이 너무 많아요. 잠시 뒤에 다시 시도해 주세요.",
    "song_unavailable": "이 PC에서는 곡 처리 기능을 쓸 수 없어요. 프로그램을 업데이트하거나 다시 설치해 주세요.",
    "storage_full": "PC의 저장 공간이 부족해서 곡을 올릴 수 없어요. 공간을 확보한 뒤 다시 시도해 주세요.",
    "enrich_timeout": "해석을 만드는 데 시간이 너무 오래 걸려요. 줄 수를 줄여서 다시 시도해 주세요.",
    "internal": "서버에서 예기치 않은 오류가 났어요. 잠시 뒤에 다시 시도해 주세요.",
}
JOB_ERR_MSG = {
    "asr_failed": "음성을 받아 적지 못했어요. 다시 시도해 주세요.",
    "no_speech": "소리가 들리지 않는 파일이에요. 다른 파일을 골라 주세요.",
    "model_missing": "음성 인식 모델을 불러오지 못했어요. PC의 설치 상태를 확인해 주세요.",
    "server_restart": "PC 프로그램이 다시 시작되어 작업이 끊겼어요. 같은 파일로 다시 시작해 주세요.",
    "internal": "곡을 처리하다 오류가 났어요. 다시 시도해 주세요.",
}

H = {}                                  # injected helpers
router = APIRouter()

ROOT = ""
_lock = threading.RLock()               # registry (UPLOADS / JOBS / QUEUE / _WORKER)
UPLOADS = {}                            # upload_id -> meta dict
JOBS = {}                               # job id -> job dict
QUEUE = []                              # queued job ids, FIFO
_WORKER = None
_ULOCKS = {}                            # upload_id -> Lock (one chunk at a time per upload)
_state = {"last_sweep": 0.0, "upload_ttl": UPLOAD_TTL, "job_ttl": JOB_TTL, "fake": False, "fake_delay": 0.0}
_enrich_pool = None
_enrich_slots = threading.BoundedSemaphore(ENRICH_PARALLEL)


class SongError(Exception):
    def __init__(self, status, code, msg=None, **extra):
        Exception.__init__(self, code)
        self.status = status
        self.code = code
        self.msg = msg or MSG.get(code, MSG["internal"])
        self.extra = extra


class _Stop(Exception):
    """the job was cancelled"""


class _Fail(Exception):
    def __init__(self, code):
        Exception.__init__(self, code)
        self.code = code


def _fail(status, code, msg=None, **extra):
    raise SongError(status, code, msg, **extra)


def _log():
    return H.get("log") or logging.getLogger("backend")


# ====================================================================================================================
# setup
# ====================================================================================================================
def _hooks():
    return os.environ.get("HOEHWA_TEST_HOOKS") == "1"


def default_root():
    return os.path.join(os.path.dirname(os.path.abspath(__file__)), "cache", "song_jobs")


def init(**helpers):
    """Inject the helpers (see the module docstring) and (re)start the job store. Test-only keyword arguments:
    root= (job folder), ttl_sec= (both TTLs), fake_asr= (bool), fake_delay= (seconds per window)."""
    global ROOT, APP_VERSION
    root = helpers.pop("root", None)
    ttl = helpers.pop("ttl_sec", None)
    fake = helpers.pop("fake_asr", None)
    delay = helpers.pop("fake_delay", None)
    if "app_version" in helpers:
        APP_VERSION = str(helpers.pop("app_version") or "")
    H.update(helpers)
    song_enrich.init(**{k: H[k] for k in ("readmode", "ollama_json", "ko_ok", "ja_reading", "ja_pron", "log", "ApiError") if H.get(k) is not None})
    if _hooks():
        root = root or os.environ.get("HOEHWA_SONG_DIR") or None
        if ttl is None and os.environ.get("HOEHWA_SONG_TTL_SEC"):
            try:
                ttl = float(os.environ["HOEHWA_SONG_TTL_SEC"])
            except ValueError:
                ttl = None
        if fake is None:
            fake = os.environ.get("HOEHWA_SONG_FAKE_ASR") == "1"
        if delay is None:
            try:
                delay = float(os.environ.get("HOEHWA_SONG_FAKE_ASR_DELAY", "0") or 0)
            except ValueError:
                delay = 0.0
    else:
        root, ttl, fake, delay = None, None, False, 0.0      # the test arguments only work with the test hooks on
    with _lock:
        ROOT = os.path.abspath(root) if root else default_root()
        _state["upload_ttl"] = float(ttl) if ttl else UPLOAD_TTL
        _state["job_ttl"] = float(ttl) if ttl else JOB_TTL
        _state["fake"] = bool(fake)
        _state["fake_delay"] = max(0.0, float(delay or 0.0))
        _state["last_sweep"] = 0.0
        UPLOADS.clear()
        JOBS.clear()
        del QUEUE[:]
        _ULOCKS.clear()
        try:
            os.makedirs(ROOT, exist_ok=True)
        except OSError:
            _log().warning("song: cannot create the job folder")
        _load_disk()
    _sweep(force=True)


def available():
    """True when the pieces a job needs are importable (PyAV for the audio, numpy for the windows). Used by /health."""
    if _state["fake"]:
        return True
    if _state.get("avail") is None:
        try:
            import importlib.util
            _state["avail"] = importlib.util.find_spec("av") is not None and importlib.util.find_spec("numpy") is not None
        except Exception:
            _state["avail"] = False
    return _state["avail"]


def _need_av():
    try:
        import av  # noqa: F401
        import numpy  # noqa: F401
    except Exception:
        _fail(503, "song_unavailable")


# ====================================================================================================================
# files: safe delete, atomic json, sizes
# ====================================================================================================================
def _is_link(path):
    try:
        st = os.lstat(path)
    except OSError:
        return False
    return stat.S_ISLNK(st.st_mode) or bool(getattr(st, "st_file_attributes", 0) & _REPARSE)


def _rm_link(path):
    """remove a link / junction itself (never what it points to)"""
    try:
        os.rmdir(path)           # directory symlink / junction on Windows
        return
    except OSError:
        pass
    try:
        os.unlink(path)          # file symlink
    except OSError:
        pass


def _unlink_file(path):
    try:
        os.unlink(path)
    except PermissionError:
        try:
            os.chmod(path, stat.S_IWRITE)
            os.unlink(path)
        except OSError:
            pass
    except FileNotFoundError:
        pass


def _rm_inner(path, depth=0):
    if depth > 6:
        return
    try:
        with os.scandir(path) as it:
            entries = list(it)
    except OSError:
        return
    for e in entries:
        try:
            st = e.stat(follow_symlinks=False)
        except OSError:
            continue
        if stat.S_ISLNK(st.st_mode) or (getattr(st, "st_file_attributes", 0) & _REPARSE):
            _rm_link(e.path)                       # a link is removed, never entered
        elif stat.S_ISDIR(st.st_mode):
            _rm_inner(e.path, depth + 1)
            try:
                os.rmdir(e.path)
            except OSError:
                pass
        else:
            _unlink_file(e.path)


def _rm_dir(path):
    """Delete a job / upload folder. Only a DIRECT child of the job root whose name matches u_<32 hex> / j_<8 hex> is touched;
    a link at that place is removed itself. Returns True when the folder is gone."""
    ap = os.path.abspath(path)
    name = os.path.basename(ap)
    if not (_UPDIR_RE.match(name) or _JOB_RE.match(name)):
        return False
    try:
        if os.path.normcase(os.path.realpath(os.path.dirname(ap))) != os.path.normcase(os.path.realpath(ROOT)):
            return False
    except OSError:
        return False
    if not os.path.lexists(ap):
        return True
    if _is_link(ap):
        _rm_link(ap)
        return not os.path.lexists(ap)
    _rm_inner(ap)
    try:
        os.rmdir(ap)
    except OSError:
        _rm_inner(ap)
        try:
            os.rmdir(ap)
        except OSError:
            pass
    return not os.path.lexists(ap)


def _write_json(path, obj):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(obj, f, ensure_ascii=False)
    last = None
    for k in range(8):
        try:
            os.replace(tmp, path)
            return
        except PermissionError as e:            # a reader holds the file for a moment (Windows)
            last = e
            time.sleep(0.02 * (k + 1))
    raise last


def _read_json(path):
    try:
        if _is_link(path):
            return None
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def _dir_size(path, depth=0):
    total = 0
    if depth > 6:
        return 0
    try:
        with os.scandir(path) as it:
            for e in it:
                try:
                    st = e.stat(follow_symlinks=False)
                except OSError:
                    continue
                if stat.S_ISLNK(st.st_mode) or (getattr(st, "st_file_attributes", 0) & _REPARSE):
                    continue
                if stat.S_ISDIR(st.st_mode):
                    total += _dir_size(e.path, depth + 1)
                else:
                    total += st.st_size
    except OSError:
        pass
    return total


def _disk_free():
    try:
        return shutil.disk_usage(ROOT).free
    except OSError:
        return 1 << 62


def _check_space(extra):
    if _dir_size(ROOT) + extra > FOLDER_MAX or _disk_free() < FOLDER_MAX:
        _fail(503, "storage_full")


def _udir(uid):
    return os.path.join(ROOT, "u_" + uid)


def _jdir(jid):
    return os.path.join(ROOT, jid)


def _safe_file(path):
    """an existing regular file that is not a link, or None"""
    try:
        st = os.lstat(path)
    except OSError:
        return None
    if stat.S_ISLNK(st.st_mode) or (getattr(st, "st_file_attributes", 0) & _REPARSE) or not stat.S_ISREG(st.st_mode):
        return None
    return path


def _safe_dir(path):
    try:
        st = os.lstat(path)
    except OSError:
        return None
    if stat.S_ISLNK(st.st_mode) or (getattr(st, "st_file_attributes", 0) & _REPARSE) or not stat.S_ISDIR(st.st_mode):
        return None
    return path


# ====================================================================================================================
# registry load / sweep
# ====================================================================================================================
def _load_disk():
    """called with _lock held: rebuild the registry from the folders (after a restart). A queued / running job becomes
    failed + server_restart; folders that do not parse are removed."""
    try:
        names = os.listdir(ROOT)
    except OSError:
        return
    for name in names:
        full = os.path.join(ROOT, name)
        if _UPDIR_RE.match(name):
            if _is_link(full):
                _rm_link(full)
                continue
            meta = _read_json(os.path.join(full, "meta.json"))
            uid = name[2:]
            if not isinstance(meta, dict) or meta.get("id") != uid:
                _rm_dir(full)
                continue
            UPLOADS[uid] = meta
        elif _JOB_RE.match(name):
            if _is_link(full):
                _rm_link(full)
                continue
            data = _read_json(os.path.join(full, "job.json"))
            if not isinstance(data, dict) or data.get("id") != name or not _UP_RE.match(str(data.get("upload_id", ""))):
                _rm_dir(full)
                continue
            job = _new_job_record(name, data["upload_id"], data.get("lang", "en"))
            for k in ("state", "stage", "pct", "warnings", "error", "created", "finished", "orig_name", "audio_bytes", "audio_sha256", "parts"):
                if k in data:
                    job[k] = data[k]
            if job["state"] in ("queued", "running"):
                job.update(state="failed", stage="", eta_sec=None, message_ko="PC 프로그램이 다시 시작되어 작업이 끊겼어요.",
                           error={"code": "server_restart", "message": JOB_ERR_MSG["server_restart"]}, finished=time.time())
                _persist_job(job)
            JOBS[name] = job


def _sweep(force=False):
    """TTL clean-up: finished jobs older than the job TTL, uploads nobody uses older than their TTL. Cheap; runs from every request."""
    now = time.time()
    ttl = min(_state["upload_ttl"], _state["job_ttl"])
    if not force and now - _state["last_sweep"] < min(30.0, ttl / 2.0):
        return
    with _lock:
        _state["last_sweep"] = now
        for jid in list(JOBS):
            j = JOBS[jid]
            if j["state"] in ("done", "failed", "cancelled") and now - float(j.get("finished") or j.get("created") or now) > _state["job_ttl"]:
                _rm_dir(_jdir(jid))
                JOBS.pop(jid, None)
        in_use = {j["upload_id"] for j in JOBS.values()}
        for uid in list(UPLOADS):
            m = UPLOADS[uid]
            if uid in in_use:
                continue
            limit = _state["job_ttl"] if m.get("done") else _state["upload_ttl"]
            if now - float(m.get("touched") or m.get("created") or now) > limit:
                _rm_dir(_udir(uid))
                UPLOADS.pop(uid, None)
                _ULOCKS.pop(uid, None)
        # a folder on disk that the registry does not know (a crashed write) is removed after the upload TTL
        try:
            names = os.listdir(ROOT)
        except OSError:
            names = []
        for name in names:
            full = os.path.join(ROOT, name)
            if (_UPDIR_RE.match(name) and name[2:] not in UPLOADS) or (_JOB_RE.match(name) and name not in JOBS):
                try:
                    age = now - os.lstat(full).st_mtime
                except OSError:
                    continue
                if age > _state["upload_ttl"]:
                    _rm_dir(full)


# ====================================================================================================================
# request helpers
# ====================================================================================================================
def _err_response(e):
    body = {"error": e.msg, "code": e.code}
    body.update(e.extra)
    return JSONResponse(body, status_code=e.status)


def _api(method, path, kind="other", status=200):
    """register `fn(data) -> dict` as an endpoint: body JSON (POST) or the query (GET) is parsed here so every malformed request
    is a 400 bad_request with a code (not FastAPI's 422); the work runs in the thread pool; SongError -> {"error","code"}."""
    def deco(fn):
        async def endpoint(request: Request):
            try:
                if method == "POST":
                    raw = await request.body()
                    if len(raw) > JSON_LIMIT[kind]:
                        _fail(413, "too_large")
                    try:
                        data = json.loads(raw.decode("utf-8")) if raw.strip() else {}
                    except (ValueError, UnicodeDecodeError):
                        data = None
                    if not isinstance(data, dict):
                        _fail(400, "bad_request")
                else:
                    data = dict(request.query_params)
                result = await run_in_threadpool(_guarded, fn, data)
                return JSONResponse(result, status_code=status)
            except SongError as e:
                return _err_response(e)
            except Exception as e:
                _log().warning("song: %s %s failed (%s)", method, path, type(e).__name__)
                return _err_response(SongError(500, "internal"))
        endpoint.__name__ = "song_" + fn.__name__.lstrip("_")
        router.add_api_route(path, endpoint, methods=[method])
        return fn
    return deco


def _guarded(fn, data):
    _sweep()
    return fn(data)


def _upload_id(v):
    if not isinstance(v, str) or not _UP_RE.match(v):
        _fail(400, "bad_request")
    return v


def _job_id(v):
    if not isinstance(v, str) or not _JOB_RE.match(v):
        _fail(400, "bad_request")
    return v


def _int(v, lo, hi, code="bad_request"):
    if isinstance(v, bool) or not isinstance(v, int) or not (lo <= v <= hi):
        _fail(400, code)
    return v


def _clean_field(v):
    if v is None:
        return ""
    if not isinstance(v, str):
        _fail(400, "bad_request")
    return _CTRL.sub(" ", unicodedata.normalize("NFC", v)).strip()[:MAX_TEXT_FIELD]


def _ulock(uid):
    with _lock:
        lk = _ULOCKS.get(uid)
        if lk is None:
            lk = _ULOCKS[uid] = threading.Lock()
        return lk


# ====================================================================================================================
# audio: probe, validate, normalise (PyAV)
# ====================================================================================================================
def _normalize_audio(src, dst):
    """Decode `src` completely (this is the validity check), write the MP3 128 kbps / 44.1 kHz / <= stereo to `dst` (or move `src`
    when it already is such an MP3). Returns (duration_sec, how) with how = "kept" | "encoded". Raises SongError."""
    _need_av()
    import av
    try:
        inp = av.open(src)
    except Exception:
        _fail(415, "bad_audio")
    out = None
    tmp = dst + ".part"
    try:
        streams = list(inp.streams.audio)
        if not streams:
            _fail(415, "bad_audio")
        s = streams[0]
        cc = s.codec_context
        channels = int(getattr(cc, "channels", 0) or 0) or 2
        keep = (str(cc.name) in ("mp3", "mp3float") and int(cc.sample_rate or 0) == NORM_RATE and 1 <= channels <= 2
                and 0 < int(cc.bit_rate or 0) <= PASS_MAX_BITRATE)
        layout = "mono" if channels == 1 else "stereo"
        rs = None
        ostream = None
        if not keep:
            out = av.open(tmp, "w", format="mp3")
            ostream = out.add_stream("libmp3lame", rate=NORM_RATE)
            ostream.layout = layout
            ostream.bit_rate = NORM_BITRATE
            rs = av.AudioResampler(format="s16p", layout=layout, rate=NORM_RATE, frame_size=1152)
        samples = 0
        rate = NORM_RATE if not keep else int(cc.sample_rate)
        limit = (MAX_SONG_SEC + 1.0) * rate
        for frame in inp.decode(s):
            if keep:
                samples += frame.samples
            else:
                for rf in rs.resample(frame):
                    samples += rf.samples
                    for pkt in ostream.encode(rf):
                        out.mux(pkt)
            if samples > limit:
                _fail(413, "too_long")
        if not keep:
            for rf in rs.resample(None):
                samples += rf.samples
                for pkt in ostream.encode(rf):
                    out.mux(pkt)
            for pkt in ostream.encode(None):
                out.mux(pkt)
            out.close()
            out = None
        dur = samples / float(rate)
        if dur < MIN_SONG_SEC:
            _fail(415, "bad_audio")
        if dur > MAX_SONG_SEC:
            _fail(413, "too_long")
        if keep:
            inp.close()
            inp = None
            os.replace(src, dst)
        else:
            os.replace(tmp, dst)
        return round(dur, 3), ("kept" if keep else "encoded")
    except SongError:
        raise
    except Exception:
        _fail(415, "bad_audio")
    finally:
        try:
            if out is not None:
                out.close()
        except Exception:
            pass
        try:
            if inp is not None:
                inp.close()
        except Exception:
            pass
        if os.path.exists(tmp):
            _unlink_file(tmp)


def _sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while True:
            b = f.read(1 << 20)
            if not b:
                break
            h.update(b)
    return h.hexdigest()


def _decode_16k(path):
    """normalised MP3 -> float32 mono 16 kHz (the same resampling as faster_whisper.audio.decode_audio)"""
    import av
    import numpy as np
    parts = []
    with av.open(path) as c:
        s = c.streams.audio[0]
        rs = av.AudioResampler(format="s16", layout="mono", rate=16000)
        for frame in c.decode(s):
            for f in rs.resample(frame):
                parts.append(f.to_ndarray().reshape(-1))
        for f in rs.resample(None):
            parts.append(f.to_ndarray().reshape(-1))
    if not parts:
        return np.zeros(0, dtype=np.float32)
    return (np.concatenate(parts).astype(np.float32) / 32768.0)


# ====================================================================================================================
# upload
# ====================================================================================================================
def _persist_upload(meta):
    d = _udir(meta["id"])
    if _safe_dir(d):
        _write_json(os.path.join(d, "meta.json"), meta)


def _drop_upload(uid):
    with _lock:
        UPLOADS.pop(uid, None)
        _ULOCKS.pop(uid, None)
    _rm_dir(_udir(uid))


def _upload_done_body(meta):
    return {"upload_id": meta["id"], "done": True, "bytes": meta["audio_bytes"], "duration": meta["duration"], "format": "mp3",
            "sha256": meta["sha256"]}


def _name_ok(v):
    if not isinstance(v, str):
        _fail(400, "bad_request")
    name = _CTRL.sub(" ", v).strip()
    base = name.replace("\\", "/").rsplit("/", 1)[-1]
    if not base or len(base) > 300:
        _fail(400, "bad_request")
    ext = base.rsplit(".", 1)[-1].lower() if "." in base else ""
    if ext not in EXTS:
        _fail(415, "bad_audio")
    return base


@_api("POST", "/song/upload", kind="upload")
def _upload_chunk(d):
    uid = _upload_id(d.get("upload_id"))
    total = _int(d.get("total"), 1, MAX_CHUNKS)
    idx = _int(d.get("index"), 0, 10 ** 9, "bad_index")
    if idx >= total:
        _fail(400, "bad_index")
    name = _name_ok(d.get("name"))
    b64 = d.get("data_b64")
    if not isinstance(b64, str) or not b64 or len(b64) > MAX_B64_CHARS:
        _fail(400, "bad_request")
    try:
        raw = base64.b64decode(b64.encode("ascii"), validate=True)
    except (binascii.Error, ValueError, UnicodeEncodeError):
        _fail(400, "bad_request")
    if not raw or len(raw) > CHUNK_BYTES:
        _fail(400, "bad_request")
    _need_av()
    with _ulock(uid):
        with _lock:
            meta = UPLOADS.get(uid)
            if meta is not None and not _safe_dir(_udir(uid)):
                UPLOADS.pop(uid, None)
                meta = None
        if meta is None:
            if idx != 0:
                _fail(409, "upload_gap", expected=0)
            _check_space(len(raw))
            d_ = _udir(uid)
            if os.path.lexists(d_):
                _rm_dir(d_)
            try:
                os.makedirs(d_)
            except OSError:
                _fail(503, "storage_full")
            now = time.time()
            meta = {"id": uid, "name": name, "total": total, "next": 0, "bytes": 0, "done": False, "created": now, "touched": now,
                    "duration": 0.0, "sha256": "", "audio_bytes": 0}
            with _lock:
                UPLOADS[uid] = meta
        else:
            if meta["total"] != total:
                _fail(400, "bad_request")
            if meta.get("done"):
                return _upload_done_body(meta)
            if idx < meta["next"]:                     # a chunk the server already has: harmless repeat
                meta["touched"] = time.time()
                return {"upload_id": uid, "received": meta["next"], "bytes": meta["bytes"]}
            if idx > meta["next"]:
                _fail(409, "upload_gap", expected=meta["next"])
            _check_space(len(raw))
        if meta["bytes"] + len(raw) > MAX_SONG_BYTES:
            _drop_upload(uid)
            _fail(413, "too_large")
        src = os.path.join(_udir(uid), "src.bin")
        try:
            if os.path.exists(src) and os.path.getsize(src) > meta["bytes"]:
                os.truncate(src, meta["bytes"])
            with open(src, "ab") as f:
                f.write(raw)
        except OSError:
            _drop_upload(uid)
            _fail(503, "storage_full")
        meta["next"] += 1
        meta["bytes"] += len(raw)
        meta["touched"] = time.time()
        if meta["next"] < total:
            try:
                _persist_upload(meta)
            except OSError:
                pass
            return {"upload_id": uid, "received": meta["next"], "bytes": meta["bytes"]}
        # last chunk: validate + normalise
        dst = os.path.join(_udir(uid), "audio.mp3")
        try:
            dur, how = _normalize_audio(src, dst)
            meta["audio_bytes"] = os.path.getsize(dst)
            meta["sha256"] = _sha256_file(dst)
        except SongError:
            _drop_upload(uid)
            raise
        except Exception:
            _drop_upload(uid)
            _fail(415, "bad_audio")
        if os.path.exists(src):
            _unlink_file(src)
        meta.update(done=True, duration=dur, touched=time.time())
        try:
            _persist_upload(meta)
        except OSError:
            pass
        _log().info("song: upload %s done (%d bytes in, %d bytes mp3, %.1f s, %s)", uid[:8], meta["bytes"], meta["audio_bytes"], dur, how)
        return _upload_done_body(meta)


@_api("GET", "/song/upload")
def _upload_status(d):
    uid = _upload_id(d.get("upload_id"))
    with _lock:
        meta = UPLOADS.get(uid)
        if meta is None or not _safe_dir(_udir(uid)):
            _fail(404, "no_upload")
        meta["touched"] = time.time()
        return {"upload_id": uid, "next": meta["next"], "bytes": meta["bytes"], "done": bool(meta.get("done"))}


# ====================================================================================================================
# jobs: create / status / cancel / result / audio / release
# ====================================================================================================================
def _new_job_record(jid, uid, lang):
    return {"id": jid, "upload_id": uid, "lang": lang, "state": "queued", "stage": "", "pct": 0, "eta_sec": None,
            "message_ko": "순서를 기다리는 중", "warnings": [], "error": None, "created": time.time(), "finished": None,
            "cancel": threading.Event(), "lines": None, "title": "", "artist": "", "lyrics_source": "none", "lrclib_id": None,
            "options": {}, "orig_name": "", "audio_bytes": 0, "audio_sha256": "", "parts": 0, "t_enrich": 0.0}


def _persist_job(job):
    """job.json holds NO lyrics and no title: ids, state, numbers only"""
    d = _jdir(job["id"])
    if not _safe_dir(d):
        return
    data = {k: job[k] for k in ("id", "upload_id", "lang", "state", "stage", "pct", "warnings", "error", "created", "finished",
                                 "orig_name", "audio_bytes", "audio_sha256", "parts")}
    try:
        _write_json(os.path.join(d, "job.json"), data)
    except OSError:
        pass


def _parse_lyrics(d):
    ly = d.get("lyrics")
    if ly is None:
        return "none", [], None
    if not isinstance(ly, dict):
        _fail(400, "bad_request")
    source = ly.get("source", "none")
    if source not in ("none", "pasted", "lrclib"):
        _fail(400, "bad_request")
    lid = ly.get("lrclib_id")
    if lid is not None:
        lid = _int(lid, 0, 1 << 40)
    raw = ly.get("lines", [])
    if source == "none":
        return "none", [], None
    if not isinstance(raw, list) or len(raw) > MAX_LINES:
        _fail(400, "bad_request")
    lines, chars = [], 0
    for it in raw:
        if not isinstance(it, dict) or not isinstance(it.get("text", ""), str):
            _fail(400, "bad_request")
        text = it.get("text", "")
        chars += len(text)
        if chars > MAX_LYRIC_CHARS:
            _fail(400, "bad_request")
        t = it.get("t")
        if t is not None:
            if isinstance(t, bool) or not isinstance(t, (int, float)) or not math.isfinite(t) or t < 0 or t > 86400:
                _fail(400, "bad_request")
            t = float(t)
        p = it.get("p", 0)
        if isinstance(p, bool) or not isinstance(p, int) or p < 0 or p > 9999:
            _fail(400, "bad_request")
        lines.append({"text": text, "t": t, "p": p})
    return source, lines, lid


def _parse_options(d):
    o = d.get("options", {})
    if o is None:
        o = {}
    if not isinstance(o, dict):
        _fail(400, "bad_request")
    out = {}
    for k, default in (("translate", True), ("gloss", True), ("verify", True), ("precise", False), ("ai_ok", False)):
        v = o.get(k, default)
        if not isinstance(v, bool):
            _fail(400, "bad_request")
        out[k] = v
    return out


def _queue_pos(job):
    if job["state"] == "running":
        return 0
    n = 1 if any(j["state"] == "running" for j in JOBS.values()) else 0
    for jid in QUEUE:
        if jid == job["id"]:
            break
        n += 1
    return n


@_api("POST", "/song/jobs", status=202)
def _job_create(d):
    uid = _upload_id(d.get("upload_id"))
    lang = d.get("lang")
    if lang not in ("en", "ja"):
        _fail(400, "bad_request")
    title, artist = _clean_field(d.get("title")), _clean_field(d.get("artist"))
    source, lines, lid = _parse_lyrics(d)
    options = _parse_options(d)
    _need_av()
    with _lock:
        meta = UPLOADS.get(uid)
        if meta is None or not _safe_dir(_udir(uid)):
            _fail(404, "no_upload")
        if not meta.get("done"):
            _fail(409, "upload_gap", expected=meta["next"])
        if any(j["upload_id"] == uid and j["state"] in ("queued", "running") for j in JOBS.values()):
            _fail(409, "job_running")
        if sum(1 for j in JOBS.values() if j["state"] in ("queued", "running")) >= QUEUE_MAX:
            _fail(429, "queue_full")
        jid = "j_" + secrets.token_hex(4)
        while jid in JOBS or os.path.lexists(_jdir(jid)):
            jid = "j_" + secrets.token_hex(4)
        try:
            os.makedirs(_jdir(jid))
        except OSError:
            _fail(503, "storage_full")
        job = _new_job_record(jid, uid, lang)
        job.update(title=title, artist=artist, lyrics_source=source, lrclib_id=lid, options=options, lines=lines,
                   orig_name=meta.get("name", ""), audio_bytes=meta["audio_bytes"], audio_sha256=meta["sha256"],
                   parts=max(1, -(-meta["audio_bytes"] // CHUNK_BYTES)))
        if any(len(x["text"]) > MAX_LINE_CHARS for x in lines):
            job["warnings"].append("lyrics_truncated")
        meta["touched"] = time.time()
        JOBS[jid] = job
        QUEUE.append(jid)
        _persist_job(job)
        pos = _queue_pos(job)
        _ensure_worker()
    _log().info("song: job %s queued (%s, %d lyric lines, ai_ok=%s)", jid, lang, len(lines), options["ai_ok"])
    return {"job": jid, "state": "queued", "queue_pos": pos}


def _status_view(job):
    err = job["error"]
    out = {"job": job["id"], "state": job["state"], "stage": job["stage"], "pct": int(job["pct"]),
           "eta_sec": job["eta_sec"], "message_ko": job["message_ko"], "warnings": list(job["warnings"]), "error": err}
    if job["state"] == "queued":
        out["queue_pos"] = _queue_pos(job)
    return out


def _get_job(jid):
    job = JOBS.get(jid)
    if job is None:
        _fail(404, "no_job")
    return job


@_api("GET", "/song/jobs/status")
def _job_status(d):
    jid = _job_id(d.get("job"))
    with _lock:
        return _status_view(_get_job(jid))


@_api("POST", "/song/jobs/cancel")
def _job_cancel(d):
    jid = _job_id(d.get("job"))
    with _lock:
        job = _get_job(jid)
        if job["state"] not in ("queued", "running"):
            return {"ok": True, "state": job["state"]}
        was_queued = job["state"] == "queued"
        job["cancel"].set()
        job.update(state="cancelled", stage="", eta_sec=None, message_ko="취소했어요", finished=time.time(), lines=None)
        if jid in QUEUE:
            QUEUE.remove(jid)
        _persist_job(job)
        if was_queued:
            _rm_dir(_jdir(jid))           # never ran: nothing else touches the folder
    _log().info("song: job %s cancelled", jid)
    return {"ok": True, "state": "cancelled"}


def _done_job(jid):
    job = _get_job(jid)
    if job["state"] != "done":
        _fail(409, "not_done")
    return job


@_api("GET", "/song/result")
def _job_result(d):
    jid = _job_id(d.get("job"))
    with _lock:
        job = _done_job(jid)
    path = _safe_file(os.path.join(_jdir(jid), "song.json"))
    song = _read_json(path) if path else None
    if not isinstance(song, dict):
        _fail(404, "no_job")
    return song


@_api("GET", "/song/audio")
def _job_audio(d):
    jid = _job_id(d.get("job"))
    try:
        part = int(d.get("part", "0"))
    except (TypeError, ValueError):
        _fail(400, "bad_index")
    with _lock:
        job = _done_job(jid)
        uid, parts, total = job["upload_id"], job["parts"], job["audio_bytes"]
        sha = job["audio_sha256"]
    if part < 0 or part >= parts:
        _fail(400, "bad_index")
    path = _safe_file(os.path.join(_udir(uid), "audio.mp3"))
    if not path:
        _fail(404, "no_job")
    try:
        with open(path, "rb") as f:
            f.seek(part * CHUNK_BYTES)
            raw = f.read(CHUNK_BYTES)
    except OSError:
        _fail(404, "no_job")
    return {"part": part, "parts": parts, "bytes": len(raw), "total_bytes": total, "data_b64": base64.b64encode(raw).decode("ascii"), "sha256": sha}


@_api("POST", "/song/jobs/release")
def _job_release(d):
    # {"job"} removes the job and its upload; {"upload_id"} alone removes an upload that never became a job (or whose job ended)
    if "job" in d:
        jid = _job_id(d.get("job"))
        with _lock:
            job = JOBS.get(jid)
            if job is None:
                return {"ok": True, "removed": False}
            if job["state"] in ("queued", "running"):
                _fail(409, "job_running")
            uid = job["upload_id"]
            JOBS.pop(jid, None)
            _rm_dir(_jdir(jid))
            others = any(j["upload_id"] == uid for j in JOBS.values())
        if not others:
            _drop_upload(uid)
        _log().info("song: job %s released", jid)
        return {"ok": True, "removed": True}
    uid = _upload_id(d.get("upload_id"))
    with _lock:
        if any(j["upload_id"] == uid and j["state"] in ("queued", "running") for j in JOBS.values()):
            _fail(409, "job_running")
        known = uid in UPLOADS
        for jid in [k for k, j in JOBS.items() if j["upload_id"] == uid]:
            JOBS.pop(jid, None)
            _rm_dir(_jdir(jid))
    _drop_upload(uid)
    return {"ok": True, "removed": known}


# ====================================================================================================================
# the worker
# ====================================================================================================================
def _ensure_worker():
    """called with _lock held"""
    global _WORKER
    if _WORKER is not None and _WORKER.is_alive():
        return
    _WORKER = threading.Thread(target=_worker_loop, name="song-job", daemon=True)
    _WORKER.start()


def _worker_loop():
    global _WORKER
    while True:
        with _lock:
            job = None
            while QUEUE:
                cand = JOBS.get(QUEUE.pop(0))
                if cand is not None and cand["state"] == "queued":
                    job = cand
                    break
            if job is None:
                _WORKER = None
                return
            job.update(state="running", stage="decode", message_ko="소리 파일을 읽는 중", t_enrich=0.0)
            _persist_job(job)
        _run_job(job)


def _set(job, **kw):
    """update the job under the lock; pct never goes back; nothing happens to a job that is no longer running"""
    with _lock:
        if job["state"] != "running":
            return
        pct = kw.pop("pct", None)
        if pct is not None:
            job["pct"] = max(job["pct"], int(max(0, min(100, pct))))
        job.update(kw)


def _finish_failed(job, code):
    with _lock:
        if job["state"] != "running":
            return
        job.update(state="failed", stage="", eta_sec=None, message_ko=JOB_ERR_MSG.get(code, JOB_ERR_MSG["internal"]),
                   error={"code": code, "message": JOB_ERR_MSG.get(code, JOB_ERR_MSG["internal"])}, finished=time.time(), lines=None)
        _persist_job(job)
    _log().info("song: job %s failed (%s)", job["id"], code)


def _run_job(job):
    jid = job["id"]
    try:
        _pipeline(job)
    except _Stop:
        pass
    except _Fail as e:
        _finish_failed(job, e.code)
    except Exception as e:
        _log().warning("song: job %s crashed (%s)", jid, type(e).__name__)
        _finish_failed(job, "internal")
    finally:
        with _lock:
            job["lines"] = None
            if job["state"] == "running":              # nothing finished it (should not happen): do not leave it running
                job.update(state="failed", stage="", eta_sec=None, error={"code": "internal", "message": JOB_ERR_MSG["internal"]},
                           message_ko=JOB_ERR_MSG["internal"], finished=time.time())
                _persist_job(job)
            cancelled = job["state"] == "cancelled"
        if cancelled:
            _rm_dir(_jdir(jid))
        with _lock:
            m = UPLOADS.get(job["upload_id"])
            if m is not None:
                m["touched"] = time.time()


# ---- the fake Whisper (test hook) ----------------------------------------------------------------------------------
_FILLER = ("alpha bravo charlie delta echo foxtrot golf hotel india juliet kilo lima mike november oscar papa quebec romeo sierra "
           "tango uniform victor whiskey xray yankee zulu").split()


class _FakeModel:
    """Looks like faster_whisper.WhisperModel.transcribe for song_asr: the windows come in order, so the model keeps the position.
    It 'hears' `words` evenly spread over the song; every call sleeps `delay` seconds (inside the caller's lock, like a real window)."""

    def __init__(self, duration, words, delay):
        self.duration = max(1.0, duration)
        self.words = words
        self.delay = delay
        self.pos = 0.0
        self.calls = 0
        self.begins = []
        step = min(0.5, max(0.05, (self.duration - 1.0) / max(1, len(words))))
        self.sched = [(0.3 + i * step, 0.3 + i * step + step * 0.8, w) for i, w in enumerate(words)]

    def begin(self, start_sec):
        """the caller says where in the song the next window starts (a real model does not need this)"""
        self.begins.append(start_sec)
        self.pos = float(start_sec)

    def transcribe(self, chunk, **kw):
        self.calls += 1
        if self.delay:
            time.sleep(self.delay)
        a = self.pos
        b = a + len(chunk) / 16000.0
        self.pos = b
        words = [SimpleNamespace(word=" " + w, start=s - a, end=e - a, probability=0.9) for s, e, w in self.sched if a <= s < b]
        if not words:
            return iter(()), None
        seg = SimpleNamespace(text=" ".join(w.word.strip() for w in words), words=words, no_speech_prob=0.0)
        return iter([seg]), None


def _fake_words(lines, lang, n=60):
    out = []
    for ln in lines:
        txt = ln["text"].strip()
        if not txt:
            continue
        if lang == "ja":
            out.extend(list(txt.replace(" ", "")))
        else:
            out.extend(txt.split())
    if out:
        return out
    return [_FILLER[i % len(_FILLER)] + ("" if i < len(_FILLER) else str(i // len(_FILLER))) for i in range(n)]


# ---- pipeline ---------------------------------------------------------------------------------------------------------
def _cancel_fn(job):
    return job["cancel"].is_set


def _chk(job):
    if job["cancel"].is_set():
        raise _Stop()


def _get_model(job, lines):
    """-> (model, run_lock, device, window_sec). Loads the model OUTSIDE the run lock (get_stt has its own load lock)."""
    lock = H.get("run_lock") or threading.Lock()
    if _state["fake"]:
        m = _FakeModel(UPLOADS[job["upload_id"]]["duration"], _fake_words(lines, job["lang"]), _state["fake_delay"])
        return m, lock, "cpu", song_asr.window_for_device("cpu")
    try:
        model = H["get_model"]()
    except Exception as e:
        _log().warning("song: model load failed (%s)", type(e).__name__)
        raise _Fail("model_missing")
    info = H.get("stt_info") or {}
    device = str(info.get("device") or "cpu")
    return model, lock, device, song_asr.window_for_device(device)


def _stage(job, stage, pct, msg, eta=None):
    _set(job, stage=stage, pct=pct, message_ko=msg, eta_sec=eta)


def _ja_tokens(job, lyr, reader):
    """Japanese + lyrics: K4 tokens first (local, no AI) so the aligned words are the same tokens the learner will see.
    -> per line [{"w","kata"}] or None"""
    idx = [k for k, l in enumerate(lyr) if l["text"].strip()]
    if not idx:
        return None
    try:
        res = song_enrich.enrich_lines("ja", [{"i": k, "text": lyr[k]["text"][:MAX_LINE_CHARS]} for k in idx], ["tokens"],
                                       allow_ai=False, cancel=_cancel_fn(job))
    except song_enrich.EnrichCancelled:
        raise _Stop()
    except Exception as e:
        _log().warning("song: first analysis pass failed (%s)", type(e).__name__)
        return None
    out = [None] * len(lyr)
    for k, ol in zip(idx, res["lines"]):
        toks = [t["w"] for t in ol.get("words", []) if t.get("w")]
        if not toks:
            continue
        kata = song_asr.contextual_readings(toks, reader) if reader else [None] * len(toks)
        out[k] = [{"w": w, "kata": k2} if k2 else {"w": w} for w, k2 in zip(toks, kata)]
    return out


def _sample_words(job, audio, duration, lang, model, lock, device, reader):
    """LRC 'verify': recognise three 30 s samples (20 / 50 / 80 %), or the whole song when it is short. Words with absolute times."""
    sr = song_asr.SR
    spans = []
    if duration <= SAMPLE_SEC * len(SAMPLE_POINTS) + 10:
        spans = [(0.0, duration)]
    else:
        for f in SAMPLE_POINTS:
            s = max(0.0, min(duration * f - SAMPLE_SEC / 2, duration - SAMPLE_SEC))
            spans.append((s, s + SAMPLE_SEC))
    words, warns = [], []
    for n, (s, e) in enumerate(spans):
        _chk(job)
        a, b = int(s * sr), min(len(audio), int(e * sr))
        if b - a < sr:
            continue
        if hasattr(model, "begin"):          # only the test fake has it
            model.begin(s)

        def prog(done, total, eta, n=n):
            _stage(job, "asr", 5 + 65 * (n + done / float(max(1, total))) / len(spans), "표본을 검사하는 중 (%d/%d)" % (n + 1, len(spans)))
        try:
            r = song_asr.transcribe_song(audio[a:b], lang, model, lock, window_sec=SAMPLE_SEC + 1.0 if len(spans) > 1 else song_asr.window_for_device(device),
                                         device=device, hint_mode="none", vad=False, progress=prog, cancel=job["cancel"], reader=reader)
        except song_asr.Cancelled:
            raise _Stop()
        except Exception as ex:
            _log().warning("song: sample transcription failed (%s)", type(ex).__name__)
            raise _Fail("asr_failed")
        for w in r["words"]:
            w = dict(w)
            w["s"] = round(w["s"] + s, 3)
            w["e"] = round(w["e"] + s, 3)
            words.append(w)
        warns.extend(x for x in r["warnings"] if x not in warns)
    return words, warns


def _nk(s):
    return "".join(c for c in unicodedata.normalize("NFKC", str(s)).casefold() if c.isalnum())


def _regroup(words, toks):
    """Japanese recognition gives single characters; the learner sees analysis tokens. -> [(token, [words it spells])] when the
    tokens spell exactly the words in order, else None."""
    out, wi = [], 0
    for tk in toks:
        key = _nk(tk["w"])
        if not key:
            continue
        acc, grp, j = "", [], wi
        while j < len(words) and len(acc) < len(key):
            wk = _nk(words[j]["w"])
            if wk and not key.startswith(acc + wk):
                return None
            acc += wk
            grp.append(words[j])
            j += 1
        if acc != key:
            return None
        out.append((tk, grp))
        wi = j
    if any(_nk(w["w"]) for w in words[wi:]):
        return None
    return out


def _merge_words(words, toks, lang):
    """aligned words (with times) + analysis tokens (lemma / level / zipf / content) -> design 5.2 words. A word may cover several
    tokens (don't = do + n't): the first content token speaks for it. Japanese characters from the recognition are joined to the
    token they spell. Words nothing matches get neutral defaults."""
    out, ti = [], 0
    ja = lang == "ja"
    if ja and toks and len(words) > len(toks):
        rg = _regroup(words, toks)
        if rg:
            for tk, grp in rg:
                out.append({"w": tk["w"], "lemma": tk.get("lemma") or tk["w"], "level": tk.get("level", "mid"), "zipf": tk.get("zipf", 0.0),
                            "s": grp[0]["s"], "e": grp[-1]["e"], "est": any(bool(g.get("est")) for g in grp),
                            "content": bool(tk["content"]) if "content" in tk else True, "reading": tk.get("reading", "")})
            return out
    for w in words:
        key = _nk(w["w"])
        rep = None
        for start in range(ti, min(len(toks), ti + 4)):
            acc, grp, j = "", [], start
            while j < len(toks) and len(acc) < len(key):
                tk = _nk(toks[j]["w"])
                if tk:
                    if not key.startswith(acc + tk):
                        break
                    acc += tk
                grp.append(toks[j])
                j += 1
            if grp and acc == key:
                rep = next((t for t in grp if t.get("content")), grp[0])
                ti = j
                break
        item = {"w": w["w"], "lemma": (rep or {}).get("lemma") or (w["w"] if ja else w["w"].lower()), "level": (rep or {}).get("level", "mid"),
                "zipf": (rep or {}).get("zipf", 0.0), "s": w["s"], "e": w["e"], "est": bool(w.get("est")),
                "content": bool(rep["content"]) if rep is not None and "content" in rep else True}
        if ja:
            item["reading"] = (rep or {}).get("reading", "")
        out.append(item)
    return out


def _uniq(into, items):
    for x in items:
        if x in ALLOWED_WARNINGS and x not in into:
            into.append(x)


def _pipeline(job):
    jid, uid, lang, opts = job["id"], job["upload_id"], job["lang"], job["options"]
    ja = lang == "ja"
    lyr = job["lines"] or []
    with _lock:
        meta = UPLOADS.get(uid)
    if meta is None:
        raise _Fail("internal")
    duration = float(meta["duration"])
    audio_path = _safe_file(os.path.join(_udir(uid), "audio.mp3"))
    if not audio_path:
        raise _Fail("internal")
    reader = H.get("ja_to_kata") if ja else None
    warns = list(job["warnings"])
    real = [l for l in lyr if l["text"].strip()]
    timed = sum(1 for l in real if l["t"] is not None)
    mode = "asr"
    if real:
        mode = "lrc" if timed * 2 >= len(real) and timed > 0 else "align"

    # -- decode
    _stage(job, "decode", 0, "소리 파일을 읽는 중")
    need_asr = mode in ("asr", "align") or (mode == "lrc" and opts["verify"])
    audio = None
    if need_asr:
        try:
            audio = _decode_16k(audio_path)
        except Exception as e:
            _log().warning("song: decode failed (%s)", type(e).__name__)
            raise _Fail("asr_failed")
    _chk(job)
    _stage(job, "decode", 5, "소리 파일을 읽었어요")

    # -- Japanese tokens first (local)
    k2_lyrics = [{"text": l["text"], "t": l["t"], "p": l["p"]} for l in lyr]
    if ja and real:
        toks = _ja_tokens(job, lyr, reader)
        if toks:
            for rec, tk in zip(k2_lyrics, toks):
                if tk:
                    rec["tokens"] = tk
    _chk(job)

    # -- recognition
    words, offset = [], 0.0
    if need_asr:
        model, lock, device, window = _get_model(job, lyr)
        _chk(job)
        if mode == "lrc":
            _stage(job, "asr", 5, "표본을 검사하는 중")
            words, w_ = _sample_words(job, audio, duration, lang, model, lock, device, reader)
            _uniq(warns, w_)
            est = song_align.estimate_lrc_offset(k2_lyrics, words, lang, reader)
            offset = float(est.get("offset", 0.0))
            if abs(offset) < OFFSET_MIN_APPLY:
                offset = 0.0
            if offset == 0.0 and est.get("in_sample", 0) >= 3 and est.get("sample_match", 0.0) < song_align.LOW_MATCH:
                _uniq(warns, ["low_match"])
        else:
            def prog(done, total, eta):
                _stage(job, "asr", 5 + 65 * done / float(max(1, total)), "받아 적는 중 (%d/%d)" % (done, total), eta)
            try:
                r = song_asr.transcribe_song(audio, lang, model, lock, window_sec=window, device=device, hint_mode="none", lyrics_lines=None,
                                             vad=False, progress=prog, cancel=job["cancel"], reader=reader)
            except song_asr.Cancelled:
                raise _Stop()
            except Exception as e:
                _log().warning("song: transcription failed (%s)", type(e).__name__)
                raise _Fail("asr_failed")
            words = r["words"]
            _uniq(warns, r["warnings"])
            if mode == "asr" and r["windows"] and r["timing"]["skipped_windows"] >= r["windows"]:
                raise _Fail("no_speech")
    audio = None
    _chk(job)

    # -- alignment
    _stage(job, "align", 70, "가사 시간을 맞추는 중")
    if mode == "asr":
        a = song_align.lines_from_asr(words, duration, lang)
        timing = a.get("timing", "word")
    elif mode == "align":
        a = song_align.align_lyrics(k2_lyrics, words, duration, lang, reader)
        timing = a.get("timing", "est")
    else:
        a = song_align.lines_from_lrc(k2_lyrics, duration, offset, lang, reader, offset_guessed=offset != 0.0)
        timing = "line"
    _uniq(warns, a.get("warnings", []))
    lines = a.get("lines", [])
    _chk(job)
    _stage(job, "align", 75, "가사 시간을 맞췄어요")
    if len(lines) > MAX_LINES:
        lines = lines[:MAX_LINES]
        _uniq(warns, ["lyrics_truncated"])

    # -- enrichment (reading / pron / tokens; translate + gloss only with options and ai_ok)
    enriched = {"lines": [], "glossary": {}, "warnings": []}
    tasks = ["reading", "tokens"] + (["translate"] if opts["translate"] else []) + (["gloss"] if opts["gloss"] else [])
    if lines:
        t0 = time.time()

        def eprog(done, total):
            frac = done / float(max(1, total))
            eta = round((time.time() - t0) / done * (total - done), 1) if done else None
            _stage(job, "enrich", 75 + 20 * frac, "읽기와 해석을 만드는 중 (%d/%d)" % (done, total), eta)
        _stage(job, "enrich", 75, "읽기와 해석을 만드는 중")
        try:
            enriched = song_enrich.enrich_lines(lang, [{"i": ln["i"], "text": ln["text"]} for ln in lines], tasks, known=[],
                                                allow_ai=bool(opts["ai_ok"]), cancel=_cancel_fn(job), progress=eprog)
        except song_enrich.EnrichCancelled:
            raise _Stop()
        except Exception as e:
            _log().warning("song: enrichment failed (%s)", type(e).__name__)
            enriched = {"lines": [], "glossary": {}, "warnings": (["ko_missing"] if opts["translate"] else []) + (["gloss_missing"] if opts["gloss"] else [])}
        _uniq(warns, enriched.get("warnings", []))
    _chk(job)

    # -- package
    _stage(job, "package", 95, "곡을 정리하는 중")
    by_i = {o.get("i"): o for o in enriched.get("lines", [])}
    out_lines = []
    for ln in lines:
        en = by_i.get(ln["i"], {})
        out_lines.append({"i": ln["i"], "p": int(ln.get("p", 0)), "t0": ln["t0"], "t1": ln["t1"], "text": ln["text"],
                          "reading": en.get("reading", ""), "pron": en.get("pron", ""), "ko": en.get("ko", ""), "conf": ln.get("conf"),
                          "est": bool(ln.get("est")), "stale": False,
                          "words": _merge_words(ln.get("words", []), en.get("words", []), lang)})
    src_name = {"asr": "asr"}.get(mode, job["lyrics_source"] if job["lyrics_source"] in ("pasted", "lrclib") else "pasted")
    song = {"v": SONG_V, "lang": lang, "title": job["title"], "artist": job["artist"], "created": int(time.time()), "duration": duration,
            "audio": {"file": "audio.mp3", "bytes": job["audio_bytes"], "sha256": job["audio_sha256"], "orig_name": job["orig_name"],
                      "parts": job["parts"]},
            "source": {"lyrics": src_name, "lrclib_id": job["lrclib_id"] if src_name == "lrclib" else None, "timing": timing,
                       "attribution": "가사: LRCLIB (lrclib.net) · 개인 학습용으로만 쓰세요" if src_name == "lrclib" else ""},
            "offset": 0.0,        # an estimated LRC offset is already inside t0 / t1 (never written twice)
            "lines": out_lines, "glossary": enriched.get("glossary", {}), "marks": {"lines": [], "words": []},
            "stats": {"plays": 0, "last": 0, "best": {}}, "warnings": warns, "app": APP_VERSION}
    d = _safe_dir(_jdir(jid))
    if not d:
        raise _Stop() if job["cancel"].is_set() else _Fail("internal")
    _write_json(os.path.join(d, "song.json"), song)
    with _lock:
        if job["state"] != "running":
            raise _Stop()
        job.update(state="done", stage="", pct=100, eta_sec=None, message_ko="끝났어요", warnings=warns, finished=time.time(), lines=None)
        _persist_job(job)
    _log().info("song: job %s done (%d lines, %d warnings)", jid, len(out_lines), len(warns))


# ====================================================================================================================
# POST /song/enrich
# ====================================================================================================================
@_api("POST", "/song/enrich")
def _enrich(d):
    lang = d.get("lang")
    if lang not in ("en", "ja"):
        _fail(400, "bad_request")
    lines = d.get("lines")
    if not isinstance(lines, list) or not lines or len(lines) > ENRICH_MAX_LINES:
        _fail(400, "bad_request")
    items, chars = [], 0
    for n, it in enumerate(lines):
        if not isinstance(it, dict) or not isinstance(it.get("text", ""), str):
            _fail(400, "bad_request")
        i = it.get("i", n)
        if isinstance(i, bool) or not isinstance(i, int) or i < 0:
            _fail(400, "bad_request")
        chars += len(it.get("text", ""))
        if chars > MAX_LYRIC_CHARS:
            _fail(400, "bad_request")
        items.append({"i": i, "text": it.get("text", "")[:MAX_LINE_CHARS]})
    tasks = d.get("tasks", ["reading", "tokens"])
    if not isinstance(tasks, list) or not tasks or any(t not in song_enrich.TASKS for t in tasks):
        _fail(400, "bad_request")
    known = d.get("known", [])
    if not isinstance(known, list) or len(known) > 3000 or any(not isinstance(k, str) for k in known):
        _fail(400, "bad_request")
    ai_ok = d.get("ai_ok", False)
    if not isinstance(ai_ok, bool):
        _fail(400, "bad_request")
    global _enrich_pool
    if not _enrich_slots.acquire(blocking=False):
        _fail(429, "queue_full")
    abort = threading.Event()
    deadline = time.monotonic() + ENRICH_TIMEOUT

    def run():
        try:
            return song_enrich.enrich_lines(lang, items, tasks, known=known, allow_ai=ai_ok,
                                            cancel=lambda: abort.is_set() or time.monotonic() > deadline)
        finally:
            _enrich_slots.release()          # freed when the work really ends (also after a timeout answer)
    try:
        with _lock:
            if _enrich_pool is None:
                _enrich_pool = ThreadPoolExecutor(max_workers=ENRICH_PARALLEL, thread_name_prefix="song-enrich")
        fut = _enrich_pool.submit(run)
    except Exception:
        _enrich_slots.release()
        raise
    try:
        return fut.result(timeout=ENRICH_TIMEOUT)
    except FutureTimeout:
        abort.set()
        _log().info("song: enrich timed out (%d lines)", len(items))
        _fail(504, "enrich_timeout")
    except song_enrich.EnrichCancelled:
        _fail(504, "enrich_timeout")


# ====================================================================================================================
# test hooks: fakes for readmode / the LLM (used by the stub server and test_song.py; never by server.py)
# ====================================================================================================================
class FakeReadmode:
    """analyze(lang, text) -> tokens like reading.analyze; gloss(lang, items) -> glosses like reading.gloss (no model, no network)"""

    def __init__(self):
        self.gloss_calls = 0

    def analyze(self, lang, text):
        toks = []
        parts = re.findall(r"[A-Za-z0-9']+|[぀-ヿ一-鿿ー]+|[^\sA-Za-z0-9'぀-ヿ一-鿿ー]+|\s+", text or "")
        for p in parts:
            isw = bool(re.match(r"[A-Za-z0-9'぀-ヿ一-鿿ー]", p))
            if isw and "'" in p and lang == "en" and not p.startswith("'") and not p.endswith("'") and p.lower().endswith("n't"):
                toks.append({"t": p[:-3], "w": True, "lemma": p[:-3].lower(), "zipf": 5.0, "level": "easy", "s": 0})
                toks.append({"t": "n't", "w": True, "lemma": "not", "zipf": 6.0, "level": "easy", "s": 0})
                continue
            if isw:
                lv = "hard" if len(p) >= 7 else ("mid" if len(p) >= 5 else "easy")
                toks.append({"t": p, "w": True, "lemma": p.lower(), "zipf": 4.0, "level": lv, "s": 0})
            else:
                toks.append({"t": p, "w": False, "s": 0})
        return {"tokens": toks, "sentences": [], "words": []}

    def gloss(self, lang, items):
        self.gloss_calls += 1
        return {"glosses": [{"i": n, "lemma": (it.get("lemma") if isinstance(it, dict) else str(it)), "pos": "명사",
                             "ko": "가짜 뜻", "ipa": "", "pron": ""} for n, it in enumerate(items or [])]}


def fake_helpers(fail_llm=False):
    """the helper set for init() that needs neither models nor network. ollama_json answers with Korean."""
    rm = FakeReadmode()
    calls = []

    def ollama_json(messages, schema, temperature=0.7, num_predict=1800, think=False, cache_key_kind=None, validate=None, **kw):
        calls.append(cache_key_kind)
        text = messages[0]["content"] if messages else ""
        if "LINE: " in text:
            return {"ko": "가짜 해석"}
        items = [m for m in re.findall(r"^(\d+)\. ", text, re.M)]
        return {"lines": [{"i": int(n), "ko": "가짜 해석"} for n in items]}

    def to_kata(s):
        return "".join(chr(ord(c) + 0x60) if 0x3041 <= ord(c) <= 0x3096 else c for c in (s or ""))

    class ApiErr(Exception):
        def __init__(self, msg, status=400, format_error=False):
            Exception.__init__(self, msg)
            self.msg, self.status, self.format_error = msg, status, format_error
    return dict(readmode=rm, ollama_json=ollama_json, ko_ok=lambda t, lang="en", required=True: bool(re.search("[가-힣]", t or "")),
                ja_reading=lambda t: "".join(chr(ord(c) - 0x60) if 0x30A1 <= ord(c) <= 0x30F6 else c for c in (t or "")),
                ja_pron=to_kata, ja_to_kata=to_kata, ApiError=ApiErr, llm_calls=calls)
