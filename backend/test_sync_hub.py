# -*- coding: utf-8 -*-
"""S5 - hub tests for the 1.2 learning-record sync (backend/sync_hub.py).

Written from docs/sync_design.md only (sections 5, 7, 8 row S5, 10.2 T-H1..T-H18, appendix A).
This file does not read or import sync_hub.py. It starts the stub server (lan_stub_server.py)
with --sync-dir pointing at a temp folder and talks to it over HTTP on 127.0.0.1.

Usage:  backend\\.venv\\Scripts\\python.exe backend\\test_sync_hub.py [--work DIR]
Output: one line per check: "[PASS] T-Hn.k ..." or "[FAIL] ..."; the last line is
        "SYNC_HUB_TEST_RESULT PASS n/m" or "SYNC_HUB_TEST_RESULT FAIL n/m".
Exit:   0 only when every check passes; 1 otherwise.
Ports:  only 18791..18799 (free ones are picked at start). Only child processes started by this
        file are stopped (terminate, then kill after a timeout). The app's own ports are never used.
Secrets: the pairing token stays in memory; it is never printed or written to a file.
"""
import argparse
import datetime
import hashlib
import http.client
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
import traceback
import urllib.parse

BACKEND = os.path.dirname(os.path.abspath(__file__))
STUB = os.path.join(BACKEND, "lan_stub_server.py")
REAL_DATA_SYNC = os.path.join(BACKEND, "data", "sync")
REAL_LAN_DEVICES = os.path.join(BACKEND, "lan_devices.json")
REAL_CONFIG = os.path.join(BACKEND, "config.json")
PORT_LO, PORT_HI = 18791, 18799
FORBIDDEN_PORTS = {8770, 8775, 8776} | set(range(8862, 8870))

SENT = "ZZSENTINEL"   # a record value; must never reach the server log
BADVAL = "ZZBADVAL"   # a bad value; must never be echoed back in an error body

RESULTS = []          # (name, ok)


# ---------------------------------------------------------------- basics

def ascii_safe(s):
    return str(s).encode("ascii", "backslashreplace").decode("ascii")


def check(name, ok, detail=""):
    ok = bool(ok)
    RESULTS.append((name, ok))
    line = "[%s] %s" % ("PASS" if ok else "FAIL", name)
    if not ok and detail:
        line += "  -- " + ascii_safe(detail).replace("\n", " | ")[:500]
    print(line, flush=True)
    return ok


def group(label, fn, *args):
    """Run one test group. An exception is a harness problem: it is recorded as a failure."""
    try:
        fn(*args)
    except Exception as exc:  # noqa: BLE001 - every failure must surface as FAIL
        tb = traceback.format_exc(limit=4)
        check("HARNESS %s group aborted (%s)" % (label, type(exc).__name__), False, "%s | %s" % (exc, tb))


def canon(v):
    return json.dumps(v, sort_keys=True, separators=(",", ":"), ensure_ascii=True)


def jparse(txt):
    if txt is None:
        return None
    if isinstance(txt, bytes):
        try:
            txt = txt.decode("utf-8")
        except UnicodeDecodeError:
            return None
    try:
        return json.loads(txt)
    except ValueError:
        return None


def read_bytes(path):
    with open(path, "rb") as fh:
        return fh.read()


def read_text(path):
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        return fh.read()


def dir_state(root):
    """md5 of every file under root (relative path -> md5). Missing folder -> marker."""
    if not os.path.isdir(root):
        return {"<missing>": "-"}
    out = {}
    for dp, _dn, fns in os.walk(root):
        for fn in fns:
            full = os.path.join(dp, fn)
            rel = os.path.relpath(full, root).replace("\\", "/")
            try:
                out[rel] = hashlib.md5(read_bytes(full)).hexdigest()
            except OSError as exc:
                out[rel] = "ERR:" + type(exc).__name__
    return out


def file_md5(path):
    if not os.path.isfile(path):
        return "<missing>"
    return hashlib.md5(read_bytes(path)).hexdigest()


def real_state():
    """Read-only fingerprint of the app's real files (hash only, never printed)."""
    return {"sync": dir_state(REAL_DATA_SYNC), "lan_devices": file_md5(REAL_LAN_DEVICES),
            "config": file_md5(REAL_CONFIG)}


def pick_ports(n):
    got = []
    for p in range(PORT_LO, PORT_HI + 1):
        if len(got) == n:
            break
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        try:
            s.bind(("127.0.0.1", p))
            got.append(p)
        except OSError:
            pass
        finally:
            s.close()
    if len(got) < n:
        raise RuntimeError("fewer than %d free ports in 18791-18799" % n)
    return got


def port_listening(p):
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(1)
    try:
        return s.connect_ex(("127.0.0.1", p)) == 0
    finally:
        s.close()


# ---------------------------------------------------------------- HTTP

def req(port, method, path, body=None, raw=None, headers=None, timeout=30):
    """Returns (status or None, body bytes). Headers given here override the defaults."""
    hdrs = dict(headers or {})
    data = None
    if raw is not None:
        data = raw
    elif body is not None:
        data = json.dumps(body, separators=(",", ":")).encode("utf-8")
    if data is not None:
        hdrs.setdefault("Content-Type", "application/json")
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=timeout)
    try:
        try:
            conn.request(method, path, body=data, headers=hdrs)
        except OSError:
            if conn.sock is None:  # could not connect at all
                return None, b"connect_failed"
            # connected, but the server may answer (e.g. 413) and close while we are still sending
        resp = conn.getresponse()
        return resp.status, resp.read()
    except (OSError, http.client.HTTPException) as exc:
        return None, type(exc).__name__.encode("ascii")
    finally:
        conn.close()


def err_is(res, status, codes):
    st, txt = res
    js = jparse(txt)
    code = js.get("code") if isinstance(js, dict) else None
    if isinstance(codes, str):
        codes = (codes,)
    return st == status and code in codes, "status=%s code=%s" % (st, code)


def is_ok(res, dup=None):
    st, txt = res
    js = jparse(txt)
    if st != 200 or not isinstance(js, dict) or js.get("ok") is not True:
        return False
    return dup is None or js.get("dup") is dup


def dev_n(i):
    return "%016x" % i


DEV_A = "a1b2c3d4e5f60718"
DEV_B = "0f1e2d3c4b5a6978"
DEV_C = "5c5c5c5c5c5c5c5c"
DEV_BAD = "bad0bad0bad0bad0"
DEV_LAN = "1a2b3c4d5e6f7a8b"


def pull(port, dev, rev=None, headers=None):
    q = "/sync/pull?device_id=" + urllib.parse.quote(dev, safe="")
    if rev is not None:
        q += "&rev=%d" % rev
    return req(port, "GET", q, headers=headers)


def push_body(dev, seq, doc, name="S5 test", kind="phone"):
    return {"v": 1, "device_id": dev, "name": name, "kind": kind, "seq": seq,
            "client_time": int(time.time()), "skew": 0, "doc": doc}


def push(port, dev, seq, doc, headers=None, **kw):
    return req(port, "POST", "/sync/push", body=push_body(dev, seq, doc, **kw), headers=headers)


def replicas_of(res):
    js = jparse(res[1])
    reps = js.get("replicas") if isinstance(js, dict) else None
    return [r for r in reps if isinstance(r, dict)] if isinstance(reps, list) else []


def replica_for(res, dev):
    return [r for r in replicas_of(res) if r.get("device_id") == dev]


# ---------------------------------------------------------------- documents (design 4.3)

def make_card(key, target, reps=4):
    return {"id": "1a2b3c", "lang": key.split("|", 1)[0], "target": target, "reading": "", "ko": "", "note": "",
            "due": 1760000000, "stability": 2.3, "difficulty": 5.1, "state": 2, "step": 0,
            "last_review": 1759900000, "reps": reps, "lapses": 0}


def make_doc(n=1, sec=600):
    tgt = "I went home " + SENT
    key = "en|" + tgt
    return {
        "v": 1,
        "progress": {
            "start": {"value": "2026-11-01", "t": 0},
            "checks": {"add": {"en-1-w0": 1760000000}, "del": {}},
            "marks": {"add": {"2026-10-15|en": 1760000000}, "del": {}},
            "xp": {"en": 100 + n, "ja": 0},
            "stats": {"en": {"lessons": n, "talks": 1}, "ja": {"lessons": 0, "talks": 0}},
            "cards": {"add": {key: 1760000000}, "del": {}, "data": {key: make_card(key, tgt)}},
            "known": {"en": {"add": {"go": 1760000000}, "del": {}}, "ja": {"add": {}, "del": {}}},
        },
        "studylog": {
            "days": {"2026-10-17": {"en": {"sec": sec, "by": {}, "n": {}, "lesson": [0, 0], "score": [0, 0]}}},
            "phon": {"en": {}, "ja": {}},
            "missions": {"cafe_order": {"stars": 2, "done_goals": 2, "last": "2026-10-16", "plays": 3}},
        },
        "prefs": {
            "daily_goal_min": {"value": 10, "t": 0},
            "lesson_source": {"value": "tatoeba", "t": 0},
            "auto_fix_cards": {"value": True, "t": 0},
            "tts_voice_en": {"value": "af_heart", "t": 0},
            "tts_voice_ja": {"value": "jf_alpha", "t": 0},
            "tts_speed": {"value": 1.0, "t": 0},
        },
    }


def _bad_doc_cases():
    """(label, mutator). Each mutator breaks exactly one rule of design 5.3."""
    def c_v2(d):
        d["v"] = 2

    def c_xp_str(d):
        d["progress"]["xp"]["en"] = BADVAL

    def c_xp_neg(d):
        d["progress"]["xp"]["en"] = -1

    def c_t_neg(d):
        d["progress"]["checks"]["add"]["en-1-w0"] = -5

    def c_t_big(d):
        d["progress"]["checks"]["add"]["en-1-w0"] = 4102444801

    def c_checks_key(d):
        d["progress"]["checks"]["add"]["EN-1-W0"] = 1760000000

    def c_marks_key(d):
        d["progress"]["marks"]["add"]["2026-10-15|xx"] = 1760000000

    def c_card_target(d):
        k = "en|" + "T" * 301
        d["progress"]["cards"]["add"] = {k: 1760000000}
        d["progress"]["cards"]["data"] = {k: make_card(k, "T" * 301)}

    def c_card_ko(d):
        d["progress"]["cards"]["data"]["en|I went home " + SENT]["ko"] = "K" * 301

    def c_cards_count(d):
        d["progress"]["cards"]["add"] = {"en|w%05d" % i: 1760000000 for i in range(3501)}
        d["progress"]["cards"]["data"] = {}

    def c_depth9(d):
        deep = {}
        cur = deep
        for _ in range(9):
            cur["d"] = {}
            cur = cur["d"]
        d["progress"]["stats"]["en"]["deep"] = deep

    def c_unknown_top(d):
        d["zz_extra"] = 1

    def c_date_key(d):
        d["studylog"]["days"]["2026/10/17"] = d["studylog"]["days"].pop("2026-10-17")

    def c_days_count(d):
        base = datetime.date(2000, 1, 1)
        d["studylog"]["days"] = {
            (base + datetime.timedelta(days=i)).isoformat():
                {"en": {"sec": 1, "by": {}, "n": {}, "lesson": [0, 0], "score": [0, 0]}}
            for i in range(801)}

    def c_stab_str(d):
        d["progress"]["cards"]["data"]["en|I went home " + SENT]["stability"] = BADVAL

    return [("v is 2", c_v2), ("xp.en is a string", c_xp_str), ("xp.en is -1", c_xp_neg),
            ("checks time is -5", c_t_neg), ("checks time above 4102444800", c_t_big),
            ("checks key uppercase", c_checks_key), ("marks key bad format", c_marks_key),
            ("card target 301 chars", c_card_target), ("card ko 301 chars", c_card_ko),
            ("cards.add 3501 entries", c_cards_count), ("nesting depth 9", c_depth9),
            ("unknown top-level key", c_unknown_top), ("days key bad format", c_date_key),
            ("days 801 entries", c_days_count), ("stability is a string", c_stab_str)]


# ---------------------------------------------------------------- server processes

class Server(object):
    def __init__(self, label, port, extra_args, ctx):
        self.label = label
        self.port = port
        self.extra = list(extra_args)
        self.log = os.path.join(ctx["logdir"], label + ".log")
        self.proc = None
        self.sync_dir = None
        self.lan = None
        ctx["servers"].append(self)

    def log_text(self):
        try:
            return read_text(self.log)
        except OSError:
            return ""

    def start(self, timeout=120):
        env = dict(os.environ)
        env["PYTHONUNBUFFERED"] = "1"
        env["PYTHONIOENCODING"] = "utf-8"
        cmd = [sys.executable, STUB, "--port", str(self.port)] + self.extra
        fh = open(self.log, "ab")
        try:
            self.proc = subprocess.Popen(cmd, cwd=BACKEND, stdin=subprocess.DEVNULL,
                                         stdout=fh, stderr=subprocess.STDOUT, env=env)
        finally:
            fh.close()
        t0 = time.time()
        while True:
            if self.proc.poll() is not None:
                if "error while attempting to bind" in self.log_text():
                    raise BindError("%s could not bind port %d" % (self.label, self.port))
                raise RuntimeError("%s exited early with code %s" % (self.label, self.proc.returncode))
            if "STUB_READY" in self.log_text():
                break
            if time.time() - t0 > timeout:
                raise RuntimeError("%s printed no STUB_READY in %ds" % (self.label, timeout))
            time.sleep(0.25)
        # STUB_READY is printed before the bind can fail, so wait a moment and re-check
        time.sleep(0.5)
        if self.proc.poll() is not None or "error while attempting to bind" in self.log_text():
            raise BindError("%s could not bind port %d" % (self.label, self.port))
        if not port_listening(self.port):
            raise RuntimeError("%s port %d not accepting connections" % (self.label, self.port))
        return self

    def stop(self):
        p = self.proc
        if p is None:
            return
        if p.poll() is None:
            p.terminate()
            try:
                p.wait(15)
            except subprocess.TimeoutExpired:
                p.kill()
                p.wait(15)
        self.proc = None

    def alive(self):
        return self.proc is not None and self.proc.poll() is None


def new_sync_dir(ctx, label):
    d = os.path.join(ctx["run"], label)
    os.makedirs(d, exist_ok=True)
    return d


class BindError(RuntimeError):
    pass


def launch(ctx, label, sync, lan=False, tries=5):
    """Start a stub on free port(s). Another process may take the port between the pick and the bind;
    then the attempt is retried on a new port (each attempt has its own log file)."""
    last = None
    for k in range(tries):
        ports = pick_ports(2 if lan else 1)
        args = ["--devices-file", ctx["devices"]]
        if sync:
            args = ["--sync-dir", sync] + args
        if lan:
            args += ["--lan-port", str(ports[1]), "--lan-enabled"]
        s = Server("%s_%d" % (label, k), ports[0], args, ctx)
        s.sync_dir = sync
        s.lan = ports[1] if lan else None
        ctx["ports"] += ports
        try:
            s.start()
            return s
        except BindError as exc:
            last = exc
            s.stop()
    raise RuntimeError("%s: no free port after %d tries (%s)" % (label, tries, last))


def start_hub(ctx, label, lan=False):
    return launch(ctx, label, new_sync_dir(ctx, "sync_" + label), lan=lan)


# ---------------------------------------------------------------- selftests (checker must fail on bad input)

def selftests(ctx):
    ok, _ = err_is((200, b'{"ok":true}'), 400, "bad_doc")
    check("SELF.1 status mismatch (200 vs 400) is detected", not ok)
    ok, _ = err_is((400, b'{"code":"bad_request"}'), 400, "bad_doc")
    check("SELF.2 code mismatch is detected", not ok)
    ok, _ = err_is((None, b"timeout"), 400, "bad_doc")
    check("SELF.3 no response is detected", not ok)
    a = make_doc(1)
    b = make_doc(2)
    check("SELF.4 different docs compare unequal", canon(a) != canon(b))
    check("SELF.5 same doc with reordered keys compares equal",
          canon(dict(reversed(list(a.items())))) == canon(a))
    d = os.path.join(ctx["work"], "selftest_state")
    os.makedirs(d, exist_ok=True)
    f = os.path.join(d, "x.json")
    with open(f, "w", encoding="utf-8") as fh:
        fh.write("1")
    s1 = dir_state(d)
    with open(f, "w", encoding="utf-8") as fh:
        fh.write("2")
    s2 = dir_state(d)
    check("SELF.6 dir_state detects a one-byte change", s1 != s2)
    check("SELF.7 broken JSON parses to None", jparse(b"{") is None)
    check("SELF.8 base doc keys follow the documented formats",
          all(re.match(r"^[a-z]{2}-\d{1,3}-[wmc]\d{1,3}$", k) for k in a["progress"]["checks"]["add"])
          and all(re.match(r"^(en|ja)\|.{1,300}$", k) for k in a["progress"]["cards"]["add"])
          and all(re.match(r"^\d{4}-\d{2}-\d{2}\|(en|ja)$", k) for k in a["progress"]["marks"]["add"]))
    shutil.rmtree(d, ignore_errors=True)


# ---------------------------------------------------------------- T-H1..T-H4 (basic push/pull, seq)

def t_h1_h4(S):
    p = S.port
    doc1 = make_doc(1)
    r1 = push(p, DEV_A, 1, doc1, name="Pixel S5", kind="phone")
    js1 = jparse(r1[1]) or {}
    rev1 = js1.get("rev")
    check("T-H1.1 push seq 1 -> 200 ok:true dup:false", is_ok(r1, dup=False), "status=%s" % r1[0])
    mine = replica_for(pull(p, DEV_B), DEV_A)
    check("T-H1.2 another device's pull shows A with identical doc",
          len(mine) == 1 and canon(mine[0].get("doc")) == canon(doc1), "found=%d" % len(mine))
    check("T-H1.3 replica meta: name, kind, seq",
          len(mine) == 1 and mine[0].get("name") == "Pixel S5" and mine[0].get("kind") == "phone"
          and mine[0].get("seq") == 1)
    check("T-H1.4 pull by A does not list A itself", not replica_for(pull(p, DEV_A), DEV_A))

    r2 = push(p, DEV_A, 1, doc1, name="Pixel S5", kind="phone")
    js2 = jparse(r2[1]) or {}
    check("T-H2.1 same seq + same body -> 200 dup:true", is_ok(r2, dup=True), "status=%s" % r2[0])
    check("T-H2.2 duplicate leaves rev unchanged", rev1 is not None and js2.get("rev") == rev1,
          "rev1=%r dup_rev=%r" % (rev1, js2.get("rev")))

    doc3 = make_doc(3)
    r3 = push(p, DEV_A, 3, doc3, name="Pixel S5", kind="phone")
    check("T-H3.0 setup: seq 3 accepted", is_ok(r3, dup=False), "status=%s" % r3[0])
    r3b = push(p, DEV_A, 2, make_doc(2), name="Pixel S5", kind="phone")
    check("T-H3.1 lower seq -> 409 stale_seq", *err_is(r3b, 409, "stale_seq"))
    check("T-H3.2 409 body carries stored_seq 3", (jparse(r3b[1]) or {}).get("stored_seq") == 3,
          "stored_seq=%r" % (jparse(r3b[1]) or {}).get("stored_seq"))

    r4 = push(p, DEV_A, 3, make_doc(33), name="Pixel S5", kind="phone")
    check("T-H4.1 same seq, different body -> 409 seq_reuse", *err_is(r4, 409, "seq_reuse"))
    mine = replica_for(pull(p, DEV_B), DEV_A)
    check("T-H4.2 rejected bodies were not stored (A still holds the seq 3 doc)",
          len(mine) == 1 and canon(mine[0].get("doc")) == canon(doc3))


# ---------------------------------------------------------------- T-H5 malformed bodies

def t_h5(S):
    p = S.port
    before = dir_state(S.sync_dir)
    cases = [("broken JSON", b"{"), ("JSON array", b"[1,2,3]"), ("empty body", b"")]
    for i, (label, raw) in enumerate(cases, 1):
        r = req(p, "POST", "/sync/push", raw=raw)
        check("T-H5.%d %s -> 400 bad_request" % (i, label), *err_is(r, 400, "bad_request"))
    check("T-H5.4 store unchanged after malformed bodies (sync dir md5 identical)",
          dir_state(S.sync_dir) == before)


# ---------------------------------------------------------------- T-H6 invalid docs

def t_h6(S):
    p = S.port
    before = dir_state(S.sync_dir)
    for k, (label, mutate) in enumerate(_bad_doc_cases(), 1):
        d = make_doc(50)
        mutate(d)
        r = push(p, DEV_BAD, k, d)
        ok, det = err_is(r, 400, "bad_doc")
        js = jparse(r[1]) or {}
        detail_ok = isinstance(js.get("detail"), str) and js.get("detail", "").startswith("doc")
        echo_ok = not (r[1] and BADVAL.encode("ascii") in r[1])
        check("T-H6.%d %s -> 400 bad_doc with doc.* path" % (k, label), ok and detail_ok and echo_ok,
              "%s detail=%r echo_ok=%s" % (det, js.get("detail"), echo_ok))
    check("T-H6.end invalid docs stored nothing (sync dir md5 identical, BAD id absent)",
          dir_state(S.sync_dir) == before and not replica_for(pull(p, DEV_B), DEV_BAD))


# ---------------------------------------------------------------- T-H7 device_id

def t_h7(S):
    p = S.port
    sync = S.sync_dir
    before = dir_state(sync)
    bad_ids = ["1A2B3C4D5E6F7081", "a1b2c3d4e5f6071", "../x", ""]
    for i, v in enumerate(bad_ids, 1):
        check("T-H7.%d pull device_id #%d (bad form) -> 400 bad_device_id" % (i, i),
              *err_is(pull(p, v), 400, "bad_device_id"))
    for i, v in enumerate(bad_ids, 1):
        check("T-H7.%d push device_id #%d (bad form) -> 400 bad_device_id" % (i + 4, i),
              *err_is(push(p, v, 1, make_doc(7)), 400, "bad_device_id"))
    outside = os.path.join(os.path.dirname(sync), "x")
    check("T-H7.9 nothing written inside or outside the sync dir",
          dir_state(sync) == before and not os.path.exists(outside)
          and not os.path.exists(os.path.join(sync, "..", "x")))


# ---------------------------------------------------------------- T-H8 body size

def t_h8(S):
    p = S.port
    before = dir_state(S.sync_dir)
    big = b'{"v":1,"pad":"' + b"x" * (3 * 1024 * 1024 + 16) + b'"}'
    r = req(p, "POST", "/sync/push", raw=big, timeout=120)
    check("T-H8.1 body over 3 MiB (loopback) -> 413 too_large", *err_is(r, 413, "too_large"))
    check("T-H8.2 store unchanged after oversized body", dir_state(S.sync_dir) == before)


# ---------------------------------------------------------------- T-H10 rev / unchanged

def t_h10(S):
    p = S.port
    js_now = jparse(pull(p, DEV_A)[1]) or {}
    cur = js_now.get("rev")
    st1, t1 = pull(p, DEV_B, rev=cur)
    js1 = jparse(t1) or {}
    need = {"v", "unchanged", "hub_id", "hub_time", "rev", "self"}
    check("T-H10.1 same rev -> unchanged:true, no replicas key, §5.2 fields",
          st1 == 200 and js1.get("unchanged") is True and need <= set(js1) and "replicas" not in js1
          and js1.get("rev") == cur, "status=%s keys=%s" % (st1, sorted(js1)))
    st2, t2 = pull(p, DEV_B, rev=cur - 1)
    js2 = jparse(t2) or {}
    need2 = {"v", "hub_id", "hub_time", "rev", "self", "replicas"}
    check("T-H10.2 different rev -> full response with replicas", st2 == 200 and need2 <= set(js2)
          and js2.get("unchanged") is not True, "status=%s keys=%s" % (st2, sorted(js2)))
    self_a = (jparse(pull(p, DEV_A)[1]) or {}).get("self") or {}
    check("T-H10.3 self.seq is 0 for a device with no replica, 3 for A",
          (js2.get("self") or {}).get("seq") == 0 and self_a.get("seq") == 3,
          "B=%r A=%r" % ((js2.get("self") or {}).get("seq"), self_a.get("seq")))


# ---------------------------------------------------------------- T-H12 loopback Host/Origin/Content-Type

def t_h12(S):
    p = S.port
    evil = {"Host": "evil.example"}
    r1 = req(p, "POST", "/sync/push", body=push_body(DEV_C, 1, make_doc(12)), headers=evil)
    check("T-H12.1 POST with Host evil.example -> 403 bad_origin", *err_is(r1, 403, "bad_origin"))
    r2 = req(p, "POST", "/sync/push", body=push_body(DEV_C, 1, make_doc(12)),
             headers={"Origin": "http://evil.example"})
    check("T-H12.2 POST with foreign Origin -> 403 bad_origin", *err_is(r2, 403, "bad_origin"))
    r3 = req(p, "POST", "/sync/push", raw=json.dumps(push_body(DEV_C, 1, make_doc(12))).encode("utf-8"),
             headers={"Content-Type": "text/plain"})
    check("T-H12.3 POST with Content-Type text/plain -> 403 bad_origin", *err_is(r3, 403, "bad_origin"))
    r4 = req(p, "GET", "/sync/pull?device_id=" + DEV_C, headers=evil)
    check("T-H12.4 GET pull with Host evil.example -> 403 bad_origin", *err_is(r4, 403, "bad_origin"))
    r5 = push(p, DEV_C, 1, make_doc(12))
    check("T-H12.5 normal loopback headers -> 200 dup:false (rejected requests stored nothing)",
          is_ok(r5, dup=False), "status=%s" % r5[0])
    r6 = req(p, "POST", "/sync/push", body=push_body(DEV_C, 2, make_doc(13)),
             headers={"Host": "localhost:%d" % p, "Origin": "http://localhost:%d" % p})
    check("T-H12.6 localhost Host with matching Origin -> 200", is_ok(r6), "status=%s" % r6[0])
    push(p, DEV_C, 3, make_doc(14))
    mine = replica_for(pull(p, DEV_B), DEV_C)
    check("T-H12.7 stored C replica is seq 3 with the last doc only",
          len(mine) == 1 and mine[0].get("seq") == 3 and canon(mine[0].get("doc")) == canon(make_doc(14)))


# ---------------------------------------------------------------- T-H11 corrupted replica file

def t_h11(S):
    p = S.port
    rep_dir = os.path.join(S.sync_dir, "replicas")
    cur_path = os.path.join(rep_dir, DEV_A + ".json")
    prev_path = cur_path + ".prev"
    prev_doc = None
    if os.path.isfile(prev_path):
        prev_doc = (jparse(read_bytes(prev_path)) or {}).get("doc")
    with open(cur_path, "wb") as fh:
        fh.write(b'{"v":1,"broken')
    st, txt = pull(p, DEV_B)
    js = jparse(txt) or {}
    check("T-H11.1 corrupted replica -> pull still 200", st == 200 and isinstance(js, dict),
          "status=%s" % st)
    mine = replica_for((st, txt), DEV_A)
    warn_ok = any(isinstance(w, dict) and w.get("device_id") == DEV_A and w.get("code") == "replica_unreadable"
                  for w in (js.get("warnings") or []))
    prev_ok = prev_doc is not None and len(mine) == 1 and canon(mine[0].get("doc")) == canon(prev_doc)
    check("T-H11.2 recovered from .prev, or warning replica_unreadable for A", prev_ok or warn_ok,
          "prev_exists=%s found=%d warn=%s" % (prev_doc is not None, len(mine), warn_ok))
    bad = [f for f in os.listdir(rep_dir) if f.startswith(DEV_A) and ".bad" in f] if os.path.isdir(rep_dir) else []
    check("T-H11.3 broken file quarantined as *.bad", len(bad) >= 1, "bad_files=%d" % len(bad))


# ---------------------------------------------------------------- T-H13 phone listener (token)

def t_h13(S, ctx):
    st, txt = req(S.port, "POST", "/lan/code", body={})
    code = (jparse(txt) or {}).get("code") if st == 200 else None
    check("T-H13.0a loopback /lan/code issues a pairing code", st == 200 and isinstance(code, str),
          "status=%s" % st)
    st2, txt2 = req(S.lan, "POST", "/pair", body={"code": code or "000000", "device_name": "S5 test"})
    token = (jparse(txt2) or {}).get("token") if st2 == 200 else None
    ctx["token"] = token if isinstance(token, str) else None
    check("T-H13.0b pairing on the phone listener returns a token", ctx["token"] is not None,
          "status=%s" % st2)
    auth = {"Authorization": "Bearer " + (ctx["token"] or "none")}
    check("T-H13.1 no token -> 401 token_missing",
          *err_is(pull(S.lan, DEV_B), 401, "token_missing"))
    check("T-H13.2 wrong token -> 401 token_invalid",
          *err_is(pull(S.lan, DEV_B, headers={"Authorization": "Bearer hp1_ZZWRONG"}), 401, "token_invalid"))
    r3 = pull(S.lan, DEV_B, headers=auth)
    check("T-H13.3 valid token -> 200", r3[0] == 200, "status=%s" % r3[0])
    r4 = push(S.lan, DEV_LAN, 1, make_doc(21), headers=auth)
    check("T-H13.4 valid token push -> 200 ok", is_ok(r4), "status=%s" % r4[0])
    check("T-H13.5 push over the phone listener is visible on loopback pull",
          len(replica_for(pull(S.port, DEV_B), DEV_LAN)) == 1)


# ---------------------------------------------------------------- T-H18 allow-list (phone listener + loopback)

def t_h18(S, ctx):
    auth = {"Authorization": "Bearer " + (ctx["token"] or "none")}
    r1 = req(S.lan, "PUT", "/sync/pull?device_id=" + DEV_B, raw=b"{}", headers=auth)
    check("T-H18.1 PUT /sync/pull on phone listener -> 403 lan_forbidden", *err_is(r1, 403, "lan_forbidden"))
    r2 = req(S.lan, "GET", "/sync/push", headers=auth)
    check("T-H18.2 GET /sync/push on phone listener -> 403 lan_forbidden", *err_is(r2, 403, "lan_forbidden"))
    r3 = req(S.lan, "POST", "/sync/pull?device_id=" + DEV_B, raw=b"{}", headers=auth)
    check("T-H18.3 POST /sync/pull on phone listener -> 403 lan_forbidden", *err_is(r3, 403, "lan_forbidden"))
    r4 = req(S.port, "PUT", "/sync/pull?device_id=" + DEV_B, raw=b"{}")
    check("T-H18.4 PUT /sync/pull on loopback -> 405 or 404 (not 200)", r4[0] in (404, 405), "status=%s" % r4[0])
    r5 = req(S.port, "GET", "/sync/push")
    check("T-H18.5 GET /sync/push on loopback -> 405 or 404", r5[0] in (404, 405), "status=%s" % r5[0])
    r6 = req(S.port, "POST", "/sync/pull?device_id=" + DEV_B, raw=b"{}")
    check("T-H18.6 POST /sync/pull on loopback -> 405 or 404", r6[0] in (404, 405), "status=%s" % r6[0])


# ---------------------------------------------------------------- T-H16 write failure injection

def t_h16(S):
    p = S.port
    run = S.sync_dir
    rep = os.path.join(run, "replicas")
    hold = os.path.join(run, "replicas_hold_s5")
    pre = dir_state(run)
    pre_rev = (jparse(read_bytes(os.path.join(run, "hub.json"))) or {}).get("rev")
    os.rename(rep, hold)
    try:
        with open(rep, "w", encoding="utf-8") as fh:
            fh.write("not a directory")
        r = push(p, DEV_A, 4, make_doc(44))
        ok, det = err_is(r, 500, "store_failed")
        ok2, det2 = err_is(r, 503, "sync_off")
        check("T-H16.1 push with unwritable replicas -> 500 store_failed (or 503)", ok or ok2,
              "%s / %s" % (det, det2))
    finally:
        os.remove(rep)
        os.rename(hold, rep)
    check("T-H16.2 existing replicas and hub files unchanged after the failed push",
          dir_state(run) == pre)
    st, txt = pull(p, DEV_B)
    check("T-H16.3 after restore: pull 200 and rev unchanged",
          st == 200 and (jparse(txt) or {}).get("rev") == pre_rev, "status=%s" % st)


# ---------------------------------------------------------------- T-H15 restart keeps state

def t_h15(ctx):
    A = ctx["A"]
    before = jparse(pull(A.port, DEV_B)[1]) or {}
    A.stop()
    A2 = launch(ctx, "A2", A.sync_dir)
    ctx["A2"] = A2
    check("T-H15.1 new server process on the same --sync-dir starts", A2.alive())
    after = jparse(pull(A2.port, DEV_B)[1]) or {}
    check("T-H15.2 hub_id unchanged after restart",
          before.get("hub_id") and before.get("hub_id") == after.get("hub_id"))
    check("T-H15.3 rev unchanged after restart", before.get("rev") is not None
          and before.get("rev") == after.get("rev"), "before=%r after=%r" % (before.get("rev"), after.get("rev")))
    check("T-H15.4 replicas unchanged after restart",
          canon(before.get("replicas")) == canon(after.get("replicas")))


# ---------------------------------------------------------------- T-H9 device cap

def t_h9(ctx):
    C = start_hub(ctx, "C")
    p = C.port
    res = [push(p, dev_n(i), 1, make_doc(i)) for i in range(1, 17)]
    check("T-H9.1 16 new devices accepted (200)", all(is_ok(r) for r in res),
          "ok=%d/16" % sum(1 for r in res if is_ok(r)))
    r17 = push(p, dev_n(0x100), 1, make_doc(99))
    check("T-H9.2 17th new device -> 409 too_many_devices", *err_is(r17, 409, "too_many_devices"))
    r_old = push(p, dev_n(3), 2, make_doc(77))
    check("T-H9.3 an existing device can still push (200)", is_ok(r_old), "status=%s" % r_old[0])
    n = len(replicas_of(pull(p, dev_n(1))))
    check("T-H9.4 pull lists at most 15 other replicas (here exactly 15)", n == 15, "n=%d" % n)
    C.stop()


# ---------------------------------------------------------------- T-H14 concurrency

def t_h14(ctx):
    D = start_hub(ctx, "D")
    p = D.port
    rev0 = (jparse(pull(p, dev_n(0x200))[1]) or {}).get("rev")
    push_res = []
    pull_res = []
    lock = threading.Lock()

    def pusher(i):
        dev = dev_n(0x200 + i)
        for seq in (1, 2, 3):
            r = push(p, dev, seq, make_doc(seq * 10 + i, sec=60 * seq + i), name="S5 %d" % i)
            with lock:
                push_res.append(r)

    def puller(j):
        for k in range(15):
            r = pull(p, dev_n(0x200 + (j + k) % 8))
            with lock:
                pull_res.append(r)

    threads = [threading.Thread(target=pusher, args=(i,)) for i in range(8)]
    threads += [threading.Thread(target=puller, args=(j,)) for j in range(4)]
    for t in threads:
        t.start()
    for t in threads:
        t.join(300)
    n_ok = sum(1 for r in push_res if is_ok(r, dup=False))
    check("T-H14.1 24 concurrent pushes (8 ids x 3) all 200 ok dup:false",
          len(push_res) == 24 and n_ok == 24, "pushes=%d ok=%d" % (len(push_res), n_ok))
    n_pull = sum(1 for st, txt in pull_res if st == 200 and isinstance(jparse(txt), dict))
    check("T-H14.2 60 concurrent pulls all 200", len(pull_res) == 60 and n_pull == 60,
          "pulls=%d ok=%d" % (len(pull_res), n_pull))
    rep = os.path.join(D.sync_dir, "replicas")
    files = [f for f in os.listdir(rep) if f.endswith(".json")] if os.path.isdir(rep) else []
    good = True
    for f in files:
        js = jparse(read_bytes(os.path.join(rep, f)))
        if not (isinstance(js, dict) and js.get("v") == 1 and js.get("seq") == 3):
            good = False
    check("T-H14.3 every replica file is valid JSON (v 1, seq 3); 8 files", good and len(files) == 8,
          "files=%d valid=%s" % (len(files), good))
    tmp_left = []
    for dp, _dn, fns in os.walk(D.sync_dir):
        tmp_left += [f for f in fns if f.endswith(".tmp")]
    check("T-H14.4 no *.tmp left in the sync dir", not tmp_left, "tmp=%d" % len(tmp_left))
    rev_end = (jparse(pull(p, dev_n(0x200))[1]) or {}).get("rev")
    check("T-H14.5 rev == rev before + 24 successful pushes",
          rev0 is not None and rev_end == rev0 + 24, "rev0=%r end=%r" % (rev0, rev_end))
    D.stop()


# ---------------------------------------------------------------- T-H17 no --sync-dir

def t_h17(ctx):
    real_before = dir_state(REAL_DATA_SYNC)
    B = launch(ctx, "B", None)   # no --sync-dir
    check("T-H17.1 no --sync-dir: GET /sync/pull -> 503 sync_off",
          *err_is(pull(B.port, DEV_B), 503, "sync_off"))
    check("T-H17.2 no --sync-dir: POST /sync/push -> 503 sync_off",
          *err_is(push(B.port, DEV_B, 1, make_doc(1)), 503, "sync_off"))
    B.stop()
    check("T-H17.3 backend/data/sync not created or changed by a sync-off server",
          dir_state(REAL_DATA_SYNC) == real_before)


# ---------------------------------------------------------------- T-H19 atomic write (tmp path squatted by a folder)

def _start_e(ctx, label, sync):
    s = launch(ctx, label, sync)
    return s, s.port


def t_h19(ctx):
    """Added on coordinator request. Writes go through <target>.tmp then os.replace. A folder squatting on
    the tmp path must make the push fail; the old bytes must stay identical; a rolled-back replica must not stay."""
    sync = new_sync_dir(ctx, "sync_E")
    main = os.path.join(sync, "replicas", DEV_A + ".json")
    hub = os.path.join(sync, "hub.json")
    E1, p1 = _start_e(ctx, "E1", sync)
    r0 = push(p1, DEV_A, 1, make_doc(1))
    check("T-H19.0 setup: first push accepted", is_ok(r0, dup=False), "status=%s" % r0[0])
    E1.stop()
    pre_main = read_bytes(main)
    pre_hub = read_bytes(hub)

    # a) replica tmp blocked: the replica write itself must fail, nothing changes
    blk_a = main + ".tmp"
    os.mkdir(blk_a)
    E2, p2 = _start_e(ctx, "E2", sync)
    ra = push(p2, DEV_A, 2, make_doc(2))
    E2.stop()
    os.rmdir(blk_a)
    check("T-H19.1 replica tmp path blocked -> 500 store_failed", *err_is(ra, 500, "store_failed"))
    check("T-H19.2 replica bytes identical after failed push", read_bytes(main) == pre_main)
    check("T-H19.3 hub.json bytes identical after failed push", read_bytes(hub) == pre_hub)

    # b) hub tmp blocked: the replica is written, then the rev bump fails -> replica must be rolled back
    blk_b = hub + ".tmp"
    os.mkdir(blk_b)
    E3, p3 = _start_e(ctx, "E3", sync)
    rb = push(p3, DEV_A, 2, make_doc(2))
    E3.stop()
    check("T-H19.4 hub tmp path blocked -> 500 store_failed", *err_is(rb, 500, "store_failed"))
    check("T-H19.5 replica rolled back to the old bytes", read_bytes(main) == pre_main)
    check("T-H19.6 hub.json bytes identical after rev-bump failure", read_bytes(hub) == pre_hub)
    os.rmdir(blk_b)

    # c) blockers removed: the same push must now succeed (the failures were caused by the blockers only)
    E4, p4 = _start_e(ctx, "E4", sync)
    rc = push(p4, DEV_A, 2, make_doc(2))
    check("T-H19.7 after removing blockers the same push -> 200 dup:false", is_ok(rc, dup=False),
          "status=%s" % rc[0])
    E4.stop()


# ---------------------------------------------------------------- T-H20 phone token vs. the PC's replica, seq jumps, via change log

def _pair_phone(S, name):
    st, txt = req(S.port, "POST", "/lan/code", body={})
    code = (jparse(txt) or {}).get("code") if st == 200 else None
    st2, txt2 = req(S.lan, "POST", "/pair", body={"code": code or "000000", "device_name": name})
    tok = (jparse(txt2) or {}).get("token") if st2 == 200 else None
    if isinstance(tok, str):
        ctx_tokens.append(tok)
        return {"Authorization": "Bearer " + tok}
    return None


ctx_tokens = []


def _stored(sync, dev):
    try:
        return json.loads(read_text(os.path.join(sync, "replicas", dev + ".json")))
    except (OSError, ValueError):
        return None


def t_h20(ctx):
    """Added on coordinator request (R1 finding). A paired phone must not overwrite the PC's replica, and a seq cannot jump far ahead."""
    S = start_hub(ctx, "H20", lan=True)
    sync = S.sync_dir
    DEV_PC, DEV_PH, DEV_P2, DEV_NEW = "7e7e7e7e7e7e7e7e", "8f8f8f8f8f8f8f8f", "9a9a9a9a9a9a9a9a", "6d6d6d6d6d6d6d6d"
    tokA = _pair_phone(S, "phone A")
    check("T-H20.0 setup: phone A paired", tokA is not None)
    if tokA is None:
        return
    # a) the PC's replica (written through loopback, kind pc)
    check("T-H20.1 setup: PC pushes its replica through loopback", is_ok(push(S.port, DEV_PC, 1, make_doc(1), kind="pc"), dup=False))
    before = read_bytes(os.path.join(sync, "replicas", DEV_PC + ".json"))
    r = push(S.lan, DEV_PC, 2, make_doc(2), headers=tokA)
    check("T-H20.2 phone token pushing the PC's id -> 403 forbidden_replica", *err_is(r, 403, "forbidden_replica"))
    check("T-H20.3 the PC's replica is byte-identical afterwards",
          read_bytes(os.path.join(sync, "replicas", DEV_PC + ".json")) == before)
    r = push(S.lan, DEV_PC, 1, make_doc(1), headers=tokA, kind="pc")
    check("T-H20.4 even the same seq/body (dup) is refused for a phone token -> 403 forbidden_replica", *err_is(r, 403, "forbidden_replica"))
    check("T-H20.5 setup: a replica first written through loopback with kind phone",
          is_ok(push(S.port, DEV_PH, 1, make_doc(3)), dup=False))
    check("T-H20.6 phone token cannot take over a replica first written through loopback -> 403 forbidden_replica",
          *err_is(push(S.lan, DEV_PH, 2, make_doc(4), headers=tokA), 403, "forbidden_replica"))
    check("T-H20.7 phone token cannot create a replica with kind pc -> 403 forbidden_replica",
          *err_is(push(S.lan, DEV_NEW, 1, make_doc(5), headers=tokA, kind="pc"), 403, "forbidden_replica"))
    check("T-H20.8 ... and nothing was created for it", _stored(sync, DEV_NEW) is None)
    check("T-H20.9 the PC itself (loopback) can still push seq 2 to its replica", is_ok(push(S.port, DEV_PC, 2, make_doc(2), kind="pc"), dup=False))
    # b) seq jumps
    check("T-H20.10 setup: phone A creates a phone replica (seq 1) and pushes seq 2",
          is_ok(push(S.lan, DEV_P2, 1, make_doc(6), headers=tokA), dup=False) and is_ok(push(S.lan, DEV_P2, 2, make_doc(7), headers=tokA), dup=False))
    snap = read_bytes(os.path.join(sync, "replicas", DEV_P2 + ".json"))
    r = push(S.lan, DEV_P2, 2 + 1001, make_doc(8), headers=tokA)
    check("T-H20.11 seq = stored + 1001 -> 400 seq_jump", *err_is(r, 400, "seq_jump"))
    r = push(S.lan, DEV_P2, 2 ** 53, make_doc(8), headers=tokA)
    check("T-H20.12 seq = 2**53 on an existing replica -> 400 seq_jump", *err_is(r, 400, "seq_jump"))
    check("T-H20.13 the replica is byte-identical after the refused jumps", read_bytes(os.path.join(sync, "replicas", DEV_P2 + ".json")) == snap)
    check("T-H20.14 seq = stored + 1000 is still accepted", is_ok(push(S.lan, DEV_P2, 2 + 1000, make_doc(9), headers=tokA), dup=False))
    check("T-H20.15 first push of a new device with seq 2**53 -> 400 seq_jump and nothing created",
          err_is(push(S.port, DEV_NEW, 2 ** 53, make_doc(10)), 400, "seq_jump")[0] and _stored(sync, DEV_NEW) is None)
    check("T-H20.16 first push with seq 2**40 + 1 -> 400 seq_jump", *err_is(push(S.port, DEV_NEW, 2 ** 40 + 1, make_doc(10)), 400, "seq_jump"))
    check("T-H20.17 first push with seq 2**40 is accepted", is_ok(push(S.port, DEV_NEW, 2 ** 40, make_doc(10)), dup=False))
    r = push(S.port, DEV_NEW, 5, make_doc(11))
    js = jparse(r[1]) or {}
    check("T-H20.18 an old seq now gets stale_seq with stored_seq 2**40", err_is(r, 409, "stale_seq")[0] and js.get("stored_seq") == 2 ** 40)
    check("T-H20.19 the stale_seq retry (stored + 1) is always accepted", is_ok(push(S.port, DEV_NEW, 2 ** 40 + 1, make_doc(12)), dup=False))
    # c) another phone token may take over a phone replica (re-pairing), and the server log notes the via change
    tokB = _pair_phone(S, "phone B")
    check("T-H20.20 setup: phone B paired", tokB is not None)
    if tokB is not None:
        r = push(S.lan, DEV_P2, 2 + 1001, make_doc(13), headers=tokB)
        check("T-H20.21 another phone token may overwrite a phone replica (re-pairing) -> 200", is_ok(r, dup=False), "status=%s" % r[0])
        via_a = (_stored(sync, DEV_P2) or {}).get("via")
        log = S.log_text()
        lines = [l for l in log.splitlines() if "via changed" in l and DEV_P2 in l]
        check("T-H20.22 the log has a 'via changed' line for that device id, without any token",
              len(lines) == 1 and not any(t in log for t in ctx_tokens),
              "lines=%d via=%s" % (len(lines), via_a))
    S.stop()


# ---------------------------------------------------------------- main

def t_h_a_block(ctx, S):
    group("T-H1..T-H4", t_h1_h4, S)
    group("T-H5", t_h5, S)
    group("T-H6", t_h6, S)
    group("T-H7", t_h7, S)
    group("T-H8", t_h8, S)
    group("T-H10", t_h10, S)
    group("T-H12", t_h12, S)
    group("T-H11", t_h11, S)
    group("T-H13", t_h13, S, ctx)
    group("T-H18", t_h18, S, ctx)
    group("T-H16", t_h16, S)
    group("T-H15", t_h15, ctx)


def main():
    ap = argparse.ArgumentParser(description="S5 hub tests")
    ap.add_argument("--work", default="", help="scratch folder for this run (created if missing)")
    args = ap.parse_args()
    if args.work:
        work = os.path.abspath(args.work)
        os.makedirs(work, exist_ok=True)
        made_work = False
    else:
        work = tempfile.mkdtemp(prefix="sync_hub_test_")
        made_work = True
    ctx = {"work": work, "logdir": os.path.join(work, "logs"), "servers": [], "ports": [], "token": None}
    os.makedirs(ctx["logdir"], exist_ok=True)
    ctx["run"] = tempfile.mkdtemp(prefix="run_", dir=work)
    ctx["devices"] = os.path.join(ctx["run"], "devices.json")
    real0 = None
    try:
        group("SELF", selftests, ctx)
        real0 = real_state()
        A = None
        try:
            A = start_hub(ctx, "A", lan=True)
            ctx["A"] = A
        except Exception as exc:  # noqa: BLE001
            check("HARNESS server A did not start (%s)" % type(exc).__name__, False, str(exc))
        if A is not None:
            group("A-block", t_h_a_block, ctx, A)
        group("T-H9", t_h9, ctx)
        group("T-H14", t_h14, ctx)
        group("T-H17", t_h17, ctx)
        group("T-H19", t_h19, ctx)
        group("T-H20", t_h20, ctx)
    except Exception as exc:  # noqa: BLE001 - unexpected harness error is a FAIL, never a silent pass
        check("HARNESS main aborted (%s)" % type(exc).__name__, False, str(exc))
    finally:
        for s in ctx["servers"]:
            s.stop()
        time.sleep(1.0)
        left = [s.label for s in ctx["servers"] if s.alive()]
        check("GUARD.2 no child process left running (own PIDs stopped)", not left, str(left))
        ports_open = [p for p in ctx["ports"] if port_listening(p)]
        check("GUARD.3 test ports released (none listening)", not ports_open, str(ports_open))
        check("GUARD.1 every port used by this run is inside 18791..18799 and not an app port",
              ctx["ports"] and all(PORT_LO <= p <= PORT_HI and p not in FORBIDDEN_PORTS for p in ctx["ports"]),
              str(ctx["ports"]))
        logtxt = "".join(s.log_text() for s in ctx["servers"])
        leak = []
        if ctx.get("token") and ctx["token"] in logtxt:
            leak.append("token")
        for pat in ("hp1_", SENT):
            if pat in logtxt:
                leak.append(pat)
        for pat in ("authorization", "bearer"):
            if pat in logtxt.lower():
                leak.append(pat)
        check("GUARD.4 server logs contain no token, Authorization/Bearer, or record sentinel",
              not leak, "leak=%s" % leak)
        if real0 is not None:
            real1 = real_state()
            check("GUARD.5 app's real backend/data/sync, lan_devices.json, config.json unchanged",
                  real1 == real0)
        if made_work:
            shutil.rmtree(work, ignore_errors=True)
        total = len(RESULTS)
        passed = sum(1 for _n, ok in RESULTS if ok)
        failed = total - passed
        verdict = "PASS" if (failed == 0 and total > 0) else "FAIL"
        print("SYNC_HUB_TEST_RESULT %s %d/%d" % (verdict, passed, total), flush=True)
        sys.exit(0 if verdict == "PASS" else 1)


if __name__ == "__main__":
    main()
