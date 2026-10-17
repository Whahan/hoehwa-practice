# -*- coding: utf-8 -*-
"""Sync hub ("기기별 기록 보관함") for the learning-record sync of v1.2. Contract: ../docs/sync_design.md section 5 (and 3.2, 7.4).

The hub never merges. Every device (the PC app through 127.0.0.1, a phone through the Tailscale listener) uploads its own replica document
and reads the other devices' documents; the merge itself is done by the apps. Two endpoints:

  GET  /sync/pull?device_id=<16 hex>[&rev=<int>]   the other devices' replicas ({"unchanged": true} when `rev` is current)
  POST /sync/push                                  this device's replica (body <= 3 MiB, structure/type/size checked, nothing else)

Storage (default <backend>/data/sync, which is update-protected, excluded from the zip and git-ignored):
  hub.json  hub.json.prev                        {"v":1,"hub_id","rev","created"}
  replicas/<device_id>.json  .json.prev  .json.bad     {"v":1,"device_id","name","kind","seq","saved_hub","via","doc"}

Rules kept here:
  * ONE process-wide lock around every read and write (the loopback server and the :8775 listener are threads of this process);
    files are written to <name>.tmp, flushed and swapped in with os.replace, so a reader never sees a half-written document.
  * A test server (server.py/lan_stub_server.py started with --port) has NO hub unless --sync-dir is given (503 sync_off), and it
    refuses the real default folder, so a test can never write the user's hub.
  * Loopback requests get the same Host / Origin / Content-Type checks as the /lan management endpoints (403 bad_origin); requests that
    came through the phone listener must carry a device that LanGate authenticated (scope["hoehwa_device"]).
  * Tokens, Authorization headers, record values (words, sentences) and device names are never logged (device id, size, seq, result only).
server.py only calls attach().
"""
import hashlib
import json
import math
import os
import re
import secrets
import threading
import time
from datetime import datetime

from fastapi import APIRouter, Request
from fastapi.responses import JSONResponse
from starlette.concurrency import run_in_threadpool

import lan

router = APIRouter()

SCHEMA = 1
BODY_LIMIT = 3 * 1024 * 1024            # bytes accepted for POST /sync/push
DRAIN_CAP = 32 * 1024 * 1024            # an oversized upload is read (and thrown away) up to this much so the client sees our 413
MAX_DEVICES = 16
SEQ_STEP_MAX = 1000                     # a push may be at most this far ahead of the stored seq (stale_seq retries use stored+1)
SEQ_FIRST_MAX = 2 ** 40                 # first push of a device
FOLDER_LIMIT = 64 * 1024 * 1024         # replicas/ + hub files
SKEW_MAX = 604800
INT_MAX = 2 ** 53
TIME_MAX = 4102444800
STR_MAX = 400
CARD_STR_MAX = 300
MAX_DEPTH = 8
LIMITS = {"cards": 3500, "known": 70000, "checks": 5000, "marks": 5000, "days": 800, "missions": 200, "phon": 80}
LEAF_KEYS_MAX = 32                      # entries of a {name: count} map (StudyLog: by / n / heard)
LEAF_KEY_LEN = 24

HEX16 = re.compile(r"[0-9a-f]{16}")
DATE_RE = re.compile(r"[0-9]{4}-[0-9]{2}-[0-9]{2}")
CHECK_RE = re.compile(r"[a-z]{2}-[0-9]{1,3}-[wmc][0-9]{1,3}")
MARK_RE = re.compile(r"[0-9]{4}-[0-9]{2}-[0-9]{2}\|(en|ja)")
CARD_KEY_RE = re.compile(r"(en|ja)\|.{1,300}", re.S)
HISTORY_RE = re.compile(r"[01]{0,30}")
LANGS = ("en", "ja")
REPLICA_FILE_RE = re.compile(r"([0-9a-f]{16})\.json(\.prev)?\Z")
PREF_KEYS = ("daily_goal_min", "lesson_source", "auto_fix_cards", "tts_voice_en", "tts_voice_ja", "tts_speed")

MSG = {
    "bad_request": "요청 형식이 올바르지 않아요.",
    "bad_device_id": "기기 번호 형식이 올바르지 않아요.",
    "bad_doc": "보낸 기록의 형식이 올바르지 않아요.",
    "bad_origin": "허용되지 않은 요청이에요. 이 PC의 앱에서만 쓸 수 있어요.",
    "too_large": "보낸 기록이 너무 커요.",
    "stale_seq": "더 오래된 기록이라 저장하지 않았어요.",
    "seq_reuse": "같은 번호로 다른 기록을 보냈어요.",
    "too_many_devices": "동기화할 수 있는 기기가 가득 찼어요.",
    "store_failed": "PC에 기록을 저장하지 못했어요.",
    "forbidden_replica": "이 기기의 기록은 이 휴대폰에서 바꿀 수 없어요.",
    "seq_jump": "보낸 번호가 저장된 번호보다 너무 많이 앞서 있어요.",
    "sync_off": "이 PC에서는 기록 동기화를 쓸 수 없어요.",
}


class _Hub:
    def __init__(self):
        self.dir = ""
        self.enabled = False
        self.log = None
        self.lock = threading.Lock()


H = _Hub()


def _err(status, code, **extra):
    msg = MSG.get(code)
    if msg is None:
        return lan._err(status, code, **extra)
    return lan._err(status, code, msg, **extra)


def _note(fmt, *args):
    if H.log is not None:
        try:
            H.log.info(fmt, *args)
        except Exception:
            pass


# ----------------------------------------------------------------------------------------------
# file helpers (callers hold H.lock)
# ----------------------------------------------------------------------------------------------
def _replicas_dir():
    return os.path.join(H.dir, "replicas")


def _hub_path():
    return os.path.join(H.dir, "hub.json")


def _replace(src, dst):
    """os.replace with a few retries: on Windows a virus scanner or a reader may hold the target for a moment (PermissionError)"""
    last = None
    for i in range(6):
        try:
            os.replace(src, dst)
            return
        except PermissionError as e:
            last = e
            time.sleep(0.05 * (i + 1))
    raise last


def _atomic_write(path, data):
    tmp = path + ".tmp"
    try:
        with open(tmp, "wb") as f:
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
        _replace(tmp, path)
    except BaseException:
        try:
            os.remove(tmp)
        except OSError:
            pass
        raise


def _read_bytes(path):
    """-> bytes | None (missing)"""
    try:
        with open(path, "rb") as f:
            return f.read()
    except FileNotFoundError:
        return None


def _loads(raw):
    """bytes -> parsed JSON | None. NaN / Infinity and anything unparsable give None."""
    if raw is None:
        return None
    try:
        return json.loads(raw.decode("utf-8"), parse_constant=_reject_constant)
    except (ValueError, UnicodeDecodeError, RecursionError):
        return None


def _reject_constant(name):
    raise ValueError("non-finite number")


def _dumps(obj):
    return json.dumps(obj, ensure_ascii=False, separators=(",", ":"), allow_nan=False).encode("utf-8")


def _canon(obj):
    return json.dumps(obj, ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False)


def _quarantine(path):
    """move a broken file out of the way (kept for inspection as <name>.bad)"""
    try:
        os.replace(path, path + ".bad")
    except OSError:
        try:
            os.remove(path)
        except OSError:
            pass


def _sweep_tmp():
    """leftovers of an interrupted write"""
    for d in (H.dir, _replicas_dir()):
        try:
            names = os.listdir(d)
        except OSError:
            continue
        for n in names:
            if n.endswith(".tmp"):
                try:
                    os.remove(os.path.join(d, n))
                except OSError:
                    pass


def _folder_bytes():
    total = 0
    for d in (H.dir, _replicas_dir()):
        try:
            for n in os.listdir(d):
                try:
                    total += os.path.getsize(os.path.join(d, n))
                except OSError:
                    pass
        except OSError:
            pass
    return total


# ----------------------------------------------------------------------------------------------
# hub.json
# ----------------------------------------------------------------------------------------------
def _hub_ok(h):
    return (isinstance(h, dict) and h.get("v") == SCHEMA and isinstance(h.get("hub_id"), str) and HEX16.fullmatch(h["hub_id"])
            and type(h.get("rev")) is int and 0 <= h["rev"] <= INT_MAX)


def _load_hub():
    """-> {"v","hub_id","rev","created"}; creates the folder and hub.json the first time. Raises OSError when the folder cannot be used."""
    os.makedirs(_replicas_dir(), exist_ok=True)
    path = _hub_path()
    raw = _read_bytes(path)
    hub = _loads(raw)
    if _hub_ok(hub):
        return hub
    if raw is not None:
        _quarantine(path)
    prev = _loads(_read_bytes(path + ".prev"))
    if _hub_ok(prev):
        # the write that broke hub.json may have been one step ahead of the .prev copy: a higher rev never matches a client's old one
        hub = {"v": SCHEMA, "hub_id": prev["hub_id"], "rev": prev["rev"] + 1, "created": str(prev.get("created") or "")}
    else:
        has_replicas = any(REPLICA_FILE_RE.fullmatch(n) for n in os.listdir(_replicas_dir()))
        hub = {"v": SCHEMA, "hub_id": secrets.token_hex(8), "rev": int(time.time()) if has_replicas else 0,
               "created": datetime.now().astimezone().isoformat(timespec="seconds")}
    _atomic_write(path, _dumps(hub))
    return hub


def _save_hub(hub):
    path = _hub_path()
    old = _read_bytes(path)
    if old is not None and _hub_ok(_loads(old)):
        _atomic_write(path + ".prev", old)
    _atomic_write(path, _dumps(hub))


# ----------------------------------------------------------------------------------------------
# replicas
# ----------------------------------------------------------------------------------------------
def _rec_ok(rec, dev):
    return (isinstance(rec, dict) and rec.get("v") == SCHEMA and rec.get("device_id") == dev and isinstance(rec.get("name"), str)
            and rec.get("kind") in ("pc", "phone") and type(rec.get("seq")) is int and rec["seq"] >= 1
            and type(rec.get("saved_hub")) is int and isinstance(rec.get("doc"), dict) and rec["doc"].get("v") == SCHEMA)


def _read_replica(dev):
    """-> (record | None, repaired: bool, unreadable: bool). A broken file is moved to .bad and the previous generation takes its place.
    unreadable = something was there but nothing usable is left."""
    main = os.path.join(_replicas_dir(), dev + ".json")
    prev = main + ".prev"
    raw = _read_bytes(main)
    rec = _loads(raw)
    if _rec_ok(rec, dev):
        return rec, False, False
    had = raw is not None
    if had:
        _quarantine(main)
    praw = _read_bytes(prev)
    prec = _loads(praw)
    if _rec_ok(prec, dev):
        _atomic_write(main, praw)         # the old generation becomes the current one again
        return prec, True, False
    if praw is not None:
        _quarantine(prev)
        had = True
    return None, had, had


def _device_ids():
    try:
        names = os.listdir(_replicas_dir())
    except OSError:
        return []
    ids = set()
    for n in names:
        m = REPLICA_FILE_RE.fullmatch(n)
        if m:
            ids.add(m.group(1))
    return sorted(ids)


def _bump(hub):
    hub["rev"] += 1
    _save_hub(hub)


# ----------------------------------------------------------------------------------------------
# validation of a replica document (structure, types, sizes; never meaning)
# ----------------------------------------------------------------------------------------------
def _t(v):
    return type(v) is int and 0 <= v <= TIME_MAX


def _n(v):
    return type(v) is int and 0 <= v <= INT_MAX


def _f(v):
    return (type(v) is int and abs(v) <= INT_MAX) or (type(v) is float and math.isfinite(v))


def _s(v, mx=STR_MAX, mn=0):
    return isinstance(v, str) and mn <= len(v) <= mx


def _too_deep(o, depth=1):
    if depth > MAX_DEPTH:
        return True
    if isinstance(o, dict):
        return any(_too_deep(v, depth + 1) for v in o.values() if isinstance(v, (dict, list)))
    if isinstance(o, list):
        return any(_too_deep(v, depth + 1) for v in o if isinstance(v, (dict, list)))
    return False


def _v_timemap(m, path, key_ok, maxn):
    """{key: time}"""
    if not isinstance(m, dict) or len(m) > maxn:
        return path
    for k, t in m.items():
        if not key_ok(k) or not _t(t):
            return path + "[key]"
    return None


def _v_addset(sec, path, key_ok, maxn):
    """{"add": {key: time}, "del": {key: time}}"""
    if not isinstance(sec, dict):
        return path
    for k, v in sec.items():
        if k not in ("add", "del"):
            return path + ".[unknown_key]"
        bad = _v_timemap(v, path + "." + k, key_ok, maxn)
        if bad:
            return bad
    return None


def _v_countmap(m, path):
    """{name: count}"""
    if not isinstance(m, dict) or len(m) > LEAF_KEYS_MAX:
        return path
    for k, v in m.items():
        if not _s(k, LEAF_KEY_LEN, 1) or not _n(v):
            return path + "[key]"
    return None


def _v_pair(v):
    return isinstance(v, list) and len(v) == 2 and _n(v[0]) and _n(v[1])


def _v_card(c, path):
    if not isinstance(c, dict):
        return path
    for k, v in c.items():
        if k == "id":
            ok = _s(v, 64)
        elif k == "lang":
            ok = v in LANGS
        elif k in ("target", "reading", "ko", "note"):
            ok = _s(v, CARD_STR_MAX)
        elif k in ("due", "last_review"):
            ok = _t(v)
        elif k in ("stability", "difficulty"):
            ok = _f(v)
        elif k in ("state", "step", "reps", "lapses"):
            ok = _n(v)
        else:
            return path + ".[unknown_key]"
        if not ok:
            return path + "." + k
    return None


def _v_progress(p):
    path = "doc.progress"
    if not isinstance(p, dict):
        return path
    for k, v in p.items():
        here = path + "." + k
        bad = None
        if k == "start":
            if not (isinstance(v, dict) and set(v) == {"value", "t"} and isinstance(v["value"], str) and DATE_RE.fullmatch(v["value"]) and _t(v["t"])):
                bad = here
        elif k == "checks":
            bad = _v_addset(v, here, lambda x: isinstance(x, str) and CHECK_RE.fullmatch(x), LIMITS["checks"])
        elif k == "marks":
            bad = _v_addset(v, here, lambda x: isinstance(x, str) and MARK_RE.fullmatch(x), LIMITS["marks"])
        elif k == "xp":
            if not isinstance(v, dict) or any(lg not in LANGS or not _n(x) for lg, x in v.items()):
                bad = here
        elif k == "stats":
            if not isinstance(v, dict):
                bad = here
            else:
                for lg, m in v.items():
                    if lg not in LANGS:
                        bad = here + "[key]"
                        break
                    bad = _v_countmap(m, here + "." + lg)
                    if bad:
                        break
        elif k == "cards":
            bad = _v_cards(v, here)
        elif k == "known":
            bad = _v_known(v, here)
        else:
            bad = path + ".[unknown_key]"
        if bad:
            return bad
    return None


def _v_cards(v, path):
    if not isinstance(v, dict):
        return path
    key_ok = lambda x: isinstance(x, str) and CARD_KEY_RE.fullmatch(x)
    for k, sec in v.items():
        here = path + "." + k
        if k in ("add", "del"):
            bad = _v_timemap(sec, here, key_ok, LIMITS["cards"])
        elif k == "data":
            if not isinstance(sec, dict) or len(sec) > LIMITS["cards"]:
                return here
            bad = None
            for ck, card in sec.items():
                if not key_ok(ck):
                    return here + "[key]"
                bad = _v_card(card, here + "[key]")
                if bad:
                    break
        else:
            return path + ".[unknown_key]"
        if bad:
            return bad
    return None


def _v_known(v, path):
    if not isinstance(v, dict):
        return path
    for lg, sec in v.items():
        here = path + "." + lg
        if lg not in LANGS or not isinstance(sec, dict):
            return here
        total = 0
        for k, m in sec.items():
            if k not in ("add", "del") or not isinstance(m, dict):
                return here + "." + k if k in ("add", "del") else here + ".[unknown_key]"
            total += len(m)
            if total > LIMITS["known"]:
                return here
            for w, t in m.items():
                if not _s(w, STR_MAX, 1) or not _t(t):
                    return here + "." + k + "[key]"
    return None


def _v_studylog(s):
    path = "doc.studylog"
    if not isinstance(s, dict):
        return path
    for k, v in s.items():
        here = path + "." + k
        bad = None
        if k == "days":
            bad = _v_days(v, here)
        elif k == "phon":
            bad = _v_phon(v, here)
        elif k == "missions":
            bad = _v_missions(v, here)
        else:
            return path + ".[unknown_key]"
        if bad:
            return bad
    return None


def _v_days(v, path):
    if not isinstance(v, dict) or len(v) > LIMITS["days"]:
        return path
    for day, langs in v.items():
        here = path + "[date]"
        if not isinstance(day, str) or not DATE_RE.fullmatch(day) or not isinstance(langs, dict):
            return here
        for lg, rec in langs.items():
            there = here + "." + str(lg)[:2]
            if lg not in LANGS or not isinstance(rec, dict):
                return there
            for k, x in rec.items():
                if k == "sec":
                    ok = _n(x)
                elif k in ("by", "n"):
                    ok = _v_countmap(x, there + "." + k) is None
                elif k in ("lesson", "score"):
                    ok = _v_pair(x)
                else:
                    return there + ".[unknown_key]"
                if not ok:
                    return there + "." + k
    return None


def _v_phon(v, path):
    if not isinstance(v, dict):
        return path
    for lg, ps in v.items():
        here = path + "." + str(lg)[:2]
        if lg not in LANGS or not isinstance(ps, dict) or len(ps) > LIMITS["phon"]:
            return here
        for p, rec in ps.items():
            if not _s(p, LEAF_KEY_LEN, 1) or not isinstance(rec, dict):
                return here + "[key]"
            for k, x in rec.items():
                if k == "h":
                    ok = isinstance(x, str) and HISTORY_RE.fullmatch(x)
                elif k == "t":
                    ok = _t(x)
                elif k == "heard":
                    ok = _v_countmap(x, here) is None
                else:
                    return here + "[key].[unknown_key]"
                if not ok:
                    return here + "[key]." + k
    return None


def _v_missions(v, path):
    if not isinstance(v, dict) or len(v) > LIMITS["missions"]:
        return path
    for mid, rec in v.items():
        here = path + "[key]"
        if not _s(mid, 64, 1) or not isinstance(rec, dict):
            return here
        for k, x in rec.items():
            if k in ("stars", "plays", "done_goals"):
                ok = _n(x)
            elif k == "last":
                ok = isinstance(x, str) and (x == "" or DATE_RE.fullmatch(x) is not None)
            else:
                return here + ".[unknown_key]"
            if not ok:
                return here + "." + k
    return None


def _v_prefs(p):
    path = "doc.prefs"
    if not isinstance(p, dict):
        return path
    for k, v in p.items():
        if k not in PREF_KEYS:
            return path + ".[unknown_key]"
        here = path + "." + k
        if not (isinstance(v, dict) and set(v) == {"value", "t"} and _t(v["t"])):
            return here
        x = v["value"]
        if not (isinstance(x, bool) or _f(x) or _s(x)):
            return here + ".value"
    return None


def validate_doc(doc):
    """-> None when the document is acceptable | "doc.progress.xp.en"-style path of the first problem (never a value)"""
    if not isinstance(doc, dict):
        return "doc"
    for k in doc:
        if k not in ("v", "progress", "studylog", "prefs"):
            return "doc.[unknown_key]"
    if type(doc.get("v")) is not int or doc["v"] != SCHEMA:
        return "doc.v"
    for k in ("progress", "studylog", "prefs"):
        if k in doc and _too_deep(doc[k], 2):
            return "doc." + k
    if "progress" in doc:
        bad = _v_progress(doc["progress"])
        if bad:
            return bad
    if "studylog" in doc:
        bad = _v_studylog(doc["studylog"])
        if bad:
            return bad
    if "prefs" in doc:
        bad = _v_prefs(doc["prefs"])
        if bad:
            return bad
    return None


# ----------------------------------------------------------------------------------------------
# request gate
# ----------------------------------------------------------------------------------------------
def _gate(request, post):
    """-> error response | None. Phone listener: LanGate must have authenticated a device. Loopback: Host / Origin / Content-Type like /lan."""
    if request.scope.get("hoehwa_lan"):
        if not request.scope.get("hoehwa_device"):
            return lan._err(401, "token_missing")
    else:
        host = request.client.host if request.client else ""
        if not lan._is_loopback(host):
            return _err(403, "bad_origin")
        hv = request.headers.get("host", "")
        if not lan.HOST_RE.match(hv):
            return _err(403, "bad_origin")
        origin = request.headers.get("origin")
        if origin is not None and origin.lower() != ("http://" + hv).lower():
            return _err(403, "bad_origin")
        if post and request.headers.get("content-type", "").split(";")[0].strip().lower() != "application/json":
            return _err(403, "bad_origin")
    if not H.enabled:
        return _err(503, "sync_off")
    return None


def _query_one(request, name):
    vals = request.query_params.getlist(name)
    return vals[0] if len(vals) == 1 else None


# ----------------------------------------------------------------------------------------------
# GET /sync/pull
# ----------------------------------------------------------------------------------------------
def _do_pull(dev, rev):
    with H.lock:
        try:
            hub = _load_hub()
        except OSError:
            return _err(503, "sync_off")
        try:
            warnings = []
            own = None
            if dev in _device_ids():
                own, repaired, _bad = _read_replica(dev)
                if repaired:
                    _bump(hub)
            peers = []
            unchanged = rev is not None and rev == hub["rev"]
            if not unchanged:                            # rev current: the answer is "unchanged", the others need not be read
                repaired = False
                for other in _device_ids():
                    if other == dev:
                        continue
                    rec, rp, unreadable = _read_replica(other)
                    repaired = repaired or rp
                    if rec is not None:
                        peers.append({"device_id": other, "name": rec["name"], "kind": rec["kind"], "seq": rec["seq"],
                                      "saved_hub": rec["saved_hub"], "doc": rec["doc"]})
                    if unreadable:
                        warnings.append({"device_id": other, "code": "replica_unreadable"})
                if repaired:
                    _bump(hub)
        except OSError:
            return _err(500, "store_failed")
        body = {"v": SCHEMA, "hub_id": hub["hub_id"], "hub_time": int(time.time()), "rev": hub["rev"],
                "self": {"seq": own["seq"] if own else 0}}
        if unchanged:
            body["unchanged"] = True
        else:
            body["replicas"] = peers
            body["warnings"] = warnings
        return JSONResponse(body)


@router.get("/sync/pull")
async def sync_pull(request: Request):
    bad = _gate(request, False)
    if bad is not None:
        return bad
    dev = _query_one(request, "device_id")
    if dev is None or not HEX16.fullmatch(dev):
        return _err(400, "bad_device_id")
    rev = None
    if "rev" in request.query_params:
        raw = _query_one(request, "rev")
        if raw is None or not re.fullmatch(r"[0-9]{1,16}", raw):
            return _err(400, "bad_request", detail="rev")
        rev = int(raw)
    return await run_in_threadpool(_do_pull, dev, rev)


# ----------------------------------------------------------------------------------------------
# POST /sync/push
# ----------------------------------------------------------------------------------------------
async def _read_body(request, limit):
    """-> bytes | None when the body is over `limit` (the rest is read and thrown away, up to DRAIN_CAP, so the client sees the answer)"""
    declared = request.headers.get("content-length")
    if declared and declared.isdigit() and int(declared) > DRAIN_CAP:
        return None
    chunks, total, over = [], 0, False
    async for chunk in request.stream():
        total += len(chunk)
        if total > limit:
            over = True
            chunks = []
        elif not over:
            chunks.append(chunk)
        if total > DRAIN_CAP:
            break
    return None if over else b"".join(chunks)


def _is_int(v, lo, hi):
    return type(v) is int and lo <= v <= hi


def _parse_push(raw):
    """-> (fields dict, None) | (None, error response)"""
    try:
        data = json.loads(raw.decode("utf-8"), parse_constant=_reject_constant) if raw.strip() else None
    except (ValueError, UnicodeDecodeError, RecursionError):
        data = None
    if not isinstance(data, dict):
        return None, _err(400, "bad_request", detail="body")
    if "v" in data and data["v"] != SCHEMA:
        return None, _err(400, "bad_request", detail="v")
    if "device_id" not in data:
        return None, _err(400, "bad_request", detail="device_id")
    dev = data["device_id"]
    if not isinstance(dev, str) or not HEX16.fullmatch(dev):
        return None, _err(400, "bad_device_id")
    name = data.get("name")
    clean = lan.CTRL_RE.sub("", name).strip() if isinstance(name, str) else ""
    if not 1 <= len(clean) <= 40:
        return None, _err(400, "bad_request", detail="name")
    if data.get("kind") not in ("pc", "phone"):
        return None, _err(400, "bad_request", detail="kind")
    if not _is_int(data.get("seq"), 1, INT_MAX):
        return None, _err(400, "bad_request", detail="seq")
    if "skew" in data and not _is_int(data["skew"], -SKEW_MAX, SKEW_MAX):
        return None, _err(400, "bad_request", detail="skew")
    if "client_time" in data and (type(data["client_time"]) is not int):
        return None, _err(400, "bad_request", detail="client_time")
    if "doc" not in data:
        return None, _err(400, "bad_request", detail="doc")
    bad = validate_doc(data["doc"])
    if bad:
        return None, _err(400, "bad_doc", detail=bad)
    return {"device_id": dev, "name": clean, "kind": data["kind"], "seq": data["seq"], "doc": data["doc"]}, None


def _do_push(f, via, size, from_phone=False):
    dev, seq = f["device_id"], f["seq"]
    with H.lock:
        try:
            hub = _load_hub()
        except OSError:
            return _err(503, "sync_off")
        try:
            stored, _rp, _bad = _read_replica(dev)
            stored_seq = stored["seq"] if stored else 0
            # a phone token must not write the PC's replica (written through loopback / kind "pc") or claim kind "pc" itself
            if from_phone and (f["kind"] == "pc" or (stored is not None and (stored.get("via") == "local" or stored["kind"] == "pc"))):
                _note("sync push device=%s seq=%d via=%s -> forbidden_replica", dev, seq, via)
                return _err(403, "forbidden_replica")
            if stored is not None:
                if seq < stored_seq:
                    return _err(409, "stale_seq", stored_seq=stored_seq)
                if seq == stored_seq:
                    same = (_canon([stored["name"], stored["kind"], stored["doc"]]) == _canon([f["name"], f["kind"], f["doc"]]))
                    if not same:
                        return _err(409, "seq_reuse", stored_seq=stored_seq)
                    return JSONResponse({"ok": True, "dup": True, "rev": hub["rev"], "hub_time": int(time.time()),
                                             "stored_seq": stored_seq, "hub_id": hub["hub_id"]})
                if seq > stored_seq + SEQ_STEP_MAX:
                    _note("sync push device=%s seq=%d stored=%d -> seq_jump", dev, seq, stored_seq)
                    return _err(400, "seq_jump", stored_seq=stored_seq)
                if stored.get("via") != via:
                    _note("sync push device=%s via changed %s -> %s", dev, stored.get("via"), via)
            else:
                if seq > SEQ_FIRST_MAX:
                    _note("sync push device=%s seq=%d -> seq_jump", dev, seq)
                    return _err(400, "seq_jump", stored_seq=0)
                if len(_device_ids()) >= MAX_DEVICES:
                    return _err(409, "too_many_devices")
            now = int(time.time())
            meta = {"v": SCHEMA, "device_id": dev, "name": f["name"], "kind": f["kind"], "seq": seq, "saved_hub": now, "via": via,
                    "doc": f["doc"]}
            data = _dumps(meta)
            main = os.path.join(_replicas_dir(), dev + ".json")
            old = _read_bytes(main)
            prev = main + ".prev"
            prev_size = os.path.getsize(prev) if os.path.exists(prev) else 0
            if _folder_bytes() - prev_size + len(data) > FOLDER_LIMIT:
                return _err(413, "too_large")
            if old is not None:
                _atomic_write(prev, old)
            _atomic_write(main, data)
            try:
                _bump(hub)
            except OSError:
                try:                                 # the rev did not move: put the old document back so peers see no half-done push
                    if old is not None:
                        _atomic_write(main, old)
                    else:
                        os.remove(main)
                except OSError:
                    pass
                raise
        except OSError as e:
            _note("sync push device=%s seq=%d bytes=%d -> store_failed (errno %s)", dev, seq, size, getattr(e, "errno", "?"))
            return _err(500, "store_failed")
        _note("sync push device=%s seq=%d bytes=%d -> ok rev=%d", dev, seq, size, hub["rev"])
        return JSONResponse({"ok": True, "dup": False, "rev": hub["rev"], "hub_time": now, "stored_seq": seq, "hub_id": hub["hub_id"]})


@router.post("/sync/push")
async def sync_push(request: Request):
    bad = _gate(request, True)
    if bad is not None:
        return bad
    raw = await _read_body(request, BODY_LIMIT)
    if raw is None:
        return _err(413, "too_large")
    fields, err = await run_in_threadpool(_parse_push, raw)
    if err is not None:
        return err
    via = str(request.scope.get("hoehwa_device") or "local")
    return await run_in_threadpool(_do_push, fields, via, len(raw), bool(request.scope.get("hoehwa_lan")))


# ----------------------------------------------------------------------------------------------
# attach
# ----------------------------------------------------------------------------------------------
def attach(app, base_dir, log, sync_dir=None, test_server=False):
    """Connect to the host app. sync_dir = hub folder (--sync-dir). Without it the real folder <base_dir>/data/sync is used, except for a
    test server (test_server=True, i.e. started with --port): that one has no hub at all (503 sync_off) and refuses the real folder."""
    default = os.path.abspath(os.path.join(base_dir, "data", "sync"))
    H.log = log
    H.dir = ""
    H.enabled = False
    if sync_dir:
        path = os.path.abspath(str(sync_dir))
        if test_server and os.path.normcase(path) == os.path.normcase(default):
            if log is not None:
                log.warning("sync hub: a test server must not use the real hub folder; hub is off")
        else:
            H.dir, H.enabled = path, True
    elif not test_server:
        H.dir, H.enabled = default, True
    if H.enabled and os.path.isdir(H.dir):
        with H.lock:
            _sweep_tmp()
    app.include_router(router)
