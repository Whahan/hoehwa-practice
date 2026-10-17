# -*- coding: utf-8 -*-
"""Tests of the phone link (lan.py, Tailscale only): pairing, tokens, allow-list, ports, source filter, bind address. No model is needed.

  .venv\\Scripts\\python.exe test_lan.py [--work-dir DIR] [--keep] [--only unit]
      Starts its OWN stub servers (lan_stub_server.py) on free ports in 8862-8869 (HTTP and link share this range), runs every
      scenario, kills only the processes it started. It never touches the app's real ports (8770, 8775, 8776).
      The link listens on the PC's Tailscale address, so the stubs run with the test hooks HOEHWA_TEST_HOOKS=1 and
      HOEHWA_LAN_ASSUME_TAILSCALE=127.0.0.1 (the "Tailscale address" is the loopback one). No test binds 0.0.0.0.
      --only unit runs the in-process checks only (no stub is started).
  .venv\\Scripts\\python.exe test_lan.py --base http://127.0.0.1:8862 --lan-port 8863 [--devices-file F] [--pid N]
      Runs the core scenarios against a server YOU started (stub or server.py --port ... --tag ... with the hooks above); --base is
      required in this mode and the app's own server is refused. Scenarios that need to start/kill processes are reported as SKIP.

Last line:  LAN_TEST_RESULT PASS n/n   (exit 0)   |   LAN_TEST_RESULT FAIL k/n | PARTIAL ...  (exit 1)
Tokens are only ever printed as their first 4 characters; codes are never printed.
"""
import base64
import hashlib
import hmac
import json
import logging
import os
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import time

import requests

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import lan  # noqa: E402  (pure helpers only: nothing is started in this process)

STUB = os.path.join(HERE, "lan_stub_server.py")
TOKEN_RE = re.compile(r"^hp1_[A-Za-z0-9_-]{43}$")
APP_PORT = 8700 + 70   # the app's own backend port: a test must never use it


def _arg(name, default=None):
    if name in sys.argv:
        i = sys.argv.index(name)
        if i + 1 < len(sys.argv):
            return sys.argv[i + 1]
    return default


def _require_base_if_given():
    """Like the other backend tests: a --base is explicit, and the app's own server is refused."""
    base = _arg("--base")
    if "--base" in sys.argv and not base:
        sys.exit("--base 가 필요해요 / --base needs a URL of YOUR test server")
    if base and base.rstrip("/").endswith(":%d" % APP_PORT):
        sys.exit("--base points at the app's server: refused. Use a test server.")
    return base.rstrip("/") if base else None


EXTERNAL = _require_base_if_given()
WORK = _arg("--work-dir") or tempfile.mkdtemp(prefix="lan_test_")
os.makedirs(WORK, exist_ok=True)

results = []     # (name, ok)
skips = []


def check(name, cond, detail=""):
    results.append((name, bool(cond)))
    print("  [%s] %s%s" % ("PASS" if cond else "FAIL", name, (" -- " + str(detail)) if detail != "" else ""), flush=True)
    return bool(cond)


def skip(name, why):
    skips.append(name)
    print("  [SKIP] %s -- %s" % (name, why), flush=True)


notes = []


def note(name, why):
    """not a check: a limitation of this PC that the report must mention (does not turn the result into a SKIP)"""
    notes.append(name)
    print("  [NOTE] %s -- %s" % (name, why), flush=True)


def mask(tok):
    return (tok or "")[:4] + ".."


# ----------------------------------------------------------------------------------------------
# helpers
# ----------------------------------------------------------------------------------------------
def tcp_free(port):
    for host in ("127.0.0.1",):          # tests never bind 0.0.0.0
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        try:
            s.bind((host, port))
        except OSError:
            return False
        finally:
            s.close()
    return True


_USED = set()


PORT_LO, PORT_HI = 8862, 8869      # every port a test uses (HTTP and link); never 8770 / 8775 / 8776


def pick():
    for p in range(PORT_LO, PORT_HI + 1):
        if p in _USED:
            continue
        if tcp_free(p):
            _USED.add(p)
            return p
    sys.exit("no free port in %d-%d" % (PORT_LO, PORT_HI))


def release(p):
    _USED.discard(p)


def own_ip():
    """a non-loopback IPv4 of this PC (the default-route one; connect() on a UDP socket sends no packet) | None"""
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("10.255.255.255", 1))
        ip = s.getsockname()[0]
        return ip if not ip.startswith("127.") else None
    except OSError:
        return None
    finally:
        s.close()


def listening_rows(port):
    """[(local address text, pid)] of the TCP LISTENING rows of `port` (netstat -ano), e.g. ("127.0.0.1", 1234) | ("0.0.0.0", ..)"""
    out = subprocess.run(["netstat", "-ano", "-p", "TCP"], capture_output=True, text=True, errors="replace").stdout
    rows = []
    for line in out.splitlines():
        p = line.split()
        if len(p) >= 5 and p[0] == "TCP" and p[3] == "LISTENING" and p[1].rsplit(":", 1)[-1] == str(port):
            rows.append((p[1].rsplit(":", 1)[0], int(p[4])))
    return rows


def listening_pids(port):
    return [pid for _, pid in listening_rows(port)]


def udp_pids():
    """PIDs that own at least one UDP endpoint (netstat -ano -p UDP)"""
    out = subprocess.run(["netstat", "-ano", "-p", "UDP"], capture_output=True, text=True, errors="replace").stdout
    pids = set()
    for line in out.splitlines():
        p = line.split()
        if len(p) >= 4 and p[0] == "UDP" and p[-1].isdigit():
            pids.add(int(p[-1]))
    return pids


def connect_code(host, port, timeout=2.0):
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(timeout)
    try:
        return s.connect_ex((host, port))
    finally:
        s.close()


def wait_closed(host, port, secs=3.0):
    t0 = time.time()
    while time.time() - t0 < secs:
        if connect_code(host, port, 1.0) != 0:
            return True, time.time() - t0
        time.sleep(0.1)
    return False, time.time() - t0


def http(method, url, token=None, auth=None, timeout=20, **kw):
    headers = dict(kw.pop("headers", {}) or {})
    if token is not None:
        headers["Authorization"] = "Bearer " + token
    if auth is not None:
        headers["Authorization"] = auth
    return requests.request(method, url, headers=headers, timeout=timeout, **kw)


def jb(r):
    try:
        return r.json()
    except Exception:
        return {}


# ----------------------------------------------------------------------------------------------
# stub process
# ----------------------------------------------------------------------------------------------
class Stub:
    live = []

    def __init__(self, name, env=None, enabled=False, devfile=None, no_hooks=False):
        self.name = name
        self.env = env or {}
        self.no_hooks = no_hooks
        self.enabled = enabled
        self.devfile = devfile or os.path.join(WORK, "dev_%s.json" % name)
        self.out_path = os.path.join(WORK, "stub_%s.out" % name)
        self.err_path = os.path.join(WORK, "stub_%s.err" % name)
        self.proc = None
        self.pid = None
        self.http_port = self.lan_port = None

    @property
    def base(self):
        return "http://127.0.0.1:%d" % self.http_port

    def lan_url(self, host="127.0.0.1"):
        return "http://%s:%d" % (host, self.lan_port)

    def start(self, keep_ports=False):
        if not keep_ports or self.http_port is None:
            self.http_port = pick()
            self.lan_port = pick()
        env = dict(os.environ)
        for k in ("HOEHWA_TEST_HOOKS", "HOEHWA_LAN_CODE_TTL", "HOEHWA_LAN_ASSUME_TAILSCALE", "HOEHWA_LAN_PREAUTH_TIMEOUT", "HOEHWA_LAN_BODY_TIMEOUT",
              "HOEHWA_LAN_HEADER_TIMEOUT", "HOEHWA_LAN_WATCH_SECONDS"):
            env.pop(k, None)
        # this PC may have no Tailscale: the stub pretends the loopback address is the Tailscale one (the stub sets these itself too)
        base_env = {} if self.no_hooks else {"HOEHWA_TEST_HOOKS": "1", "HOEHWA_LAN_ASSUME_TAILSCALE": "127.0.0.1"}
        base_env.update(self.env)
        env.update({k: v for k, v in base_env.items() if v is not None})
        cmd = [sys.executable, STUB, "--port", str(self.http_port), "--lan-port", str(self.lan_port), "--devices-file", self.devfile,
               "--tag", self.name]
        if self.enabled:
            cmd.append("--lan-enabled")
        if self.no_hooks:
            cmd.append("--no-hooks")
        self.out = open(self.out_path, "a", encoding="utf-8")
        self.err = open(self.err_path, "a", encoding="utf-8")
        self.proc = subprocess.Popen(cmd, stdout=self.out, stderr=self.err, env=env, cwd=HERE)
        Stub.live.append(self)
        t0 = time.time()
        while time.time() - t0 < 40:
            if self.proc.poll() is not None:
                raise RuntimeError("stub %s exited early (code %s), see %s" % (self.name, self.proc.returncode, self.err_path))
            try:
                if requests.get(self.base + "/health", timeout=1.5).status_code == 200:
                    break
            except requests.RequestException:
                time.sleep(0.2)
        else:
            raise RuntimeError("stub %s did not come up" % self.name)
        with open(self.out_path, "r", encoding="utf-8") as f:
            m = re.findall(r"STUB_READY pid=(\d+)", f.read())
        self.pid = int(m[-1]) if m else self.proc.pid
        return self

    def stop(self):
        if self.proc is not None and self.proc.poll() is None:
            subprocess.run(["taskkill", "/T", "/F", "/PID", str(self.proc.pid)], capture_output=True)
            try:
                self.proc.wait(10)
            except subprocess.TimeoutExpired:
                pass
        for f in (getattr(self, "out", None), getattr(self, "err", None)):
            try:
                f.close()
            except Exception:
                pass
        if self in Stub.live:
            Stub.live.remove(self)

    def release_ports(self):
        for p in (self.http_port, self.lan_port):
            release(p)


# ----------------------------------------------------------------------------------------------
# API shorthands against a "target" T (.base .lan_port .devfile .pid)
# ----------------------------------------------------------------------------------------------
def get_lan(T):
    r = http("GET", T.base + "/lan")
    return jb(r)


def set_lan(T, **body):
    return http("POST", T.base + "/lan", json=body)


def new_code(T):
    r = http("POST", T.base + "/lan/code", json={})
    return jb(r).get("code", "")


def do_pair(T, host="127.0.0.1", name="Pixel 8", code=None):
    c = code if code is not None else new_code(T)
    return http("POST", "http://%s:%d/pair" % (host, T.lan_port), json={"code": c, "device_name": name})


def pair_token(T, name="Pixel 8"):
    r = do_pair(T, name=name)
    b = jb(r)
    return (b.get("token", ""), b.get("device_id", "")) if r.status_code == 200 else ("", "")


def lurl(T, path="", host="127.0.0.1"):
    return "http://%s:%d%s" % (host, T.lan_port, path)


class Ext:
    """target description for --base mode"""

    def __init__(self, base, lan_port):
        self.base, self.lan_port = base, lan_port
        self.devfile = _arg("--devices-file")
        self.pid = int(_arg("--pid")) if _arg("--pid") else None
        self.http_port = int(base.rsplit(":", 1)[-1])


# ----------------------------------------------------------------------------------------------
# scenarios
# ----------------------------------------------------------------------------------------------
def unit_checks():
    print("\n== helpers (in-process, nothing started)")
    gone = ("private_addresses", "_is_private_lan", "_Discovery", "_network_via", "_network_ok", "_forced_private", "_unsafe_message", "_local_is_tailscale")
    check("U-01 the LAN-era helpers are gone (private addresses, UDP discovery, allow_* network switches): the link is Tailscale only",
          not [n for n in gone if hasattr(lan, n)], [n for n in gone if hasattr(lan, n)])
    check("U-02 DEFAULT_LAN is exactly enabled=false, port=8775, name='' (no discovery / allow_* keys)",
          lan.DEFAULT_LAN == {"enabled": False, "port": 8775, "name": ""}, lan.DEFAULT_LAN)
    check("U-03 loopback test: 127.0.0.1 / ::1 / ::ffff:127.0.0.1 yes, 192.168.0.1 / empty no",
          lan._is_loopback("127.0.0.1") and lan._is_loopback("::1") and lan._is_loopback("::ffff:127.0.0.1")
          and not lan._is_loopback("192.168.0.1") and not lan._is_loopback(""))
    new_routes = {("GET", "/practice/ping"), ("GET", "/practice/sentences"), ("GET", "/practice/phonemes"), ("GET", "/practice/phoneme"),
                  ("GET", "/missions"), ("POST", "/missions/check"), ("POST", "/missions/judge")}
    check("U-04 allow-list has exactly the 16 original + 7 English v1.1 routes and none of /mic /llm /lan(admin) /docs",
          len(lan.ALLOW) == 23 and new_routes <= lan.ALLOW and not any(p.startswith("/practice") or p.startswith("/missions") for _, p in lan.ALLOW - new_routes) and not any(p.startswith(("/mic", "/llm", "/docs", "/debug")) for _, p in lan.ALLOW)
          and ("GET", "/lan") not in lan.ALLOW and ("POST", "/lan/code") not in lan.ALLOW)
def core(T, ip2):
    """B-03 .. B-23 on target T (LAN off at the start). ip2 = a non-loopback IPv4 of this PC | None: the link is bound to the
    Tailscale address only (here: loopback through the test hook), so this other address of the PC must refuse"""
    L = T.lan_port
    stub = bool(jb(http("GET", T.base + "/health")).get("stub"))     # only the stub gives canned 200s; a real server may lack models
    print("\n== core scenarios (%s)" % (("stub " + T.name) if hasattr(T, "name") else ("external server, stub=%s" % stub)))
    # ---- B-03 default: off
    st = get_lan(T)
    check("B-03a default: GET /lan -> enabled false, listening false", st.get("enabled") is False and st.get("listening") is False, st.get("error", ""))
    check("B-03b default: LAN port refuses 127.0.0.1", connect_code("127.0.0.1", L) != 0)
    if ip2:
        check("B-03c default: LAN port refuses this PC's non-loopback address (%s)" % ip2, connect_code(ip2, L) != 0)
    check("B-07a loopback GET /health without token, LAN off -> 200", http("GET", T.base + "/health").status_code == 200)
    hl = jb(http("GET", T.base + "/hello"))
    check("hello (loopback, off): keys hoehwa,name,pairing_open and pairing_open false",
          set(hl) == {"hoehwa", "name", "pairing_open"} and hl.get("hoehwa") == 1 and hl.get("pairing_open") is False, hl)
    check("B-03d while off the server owns no UDP socket", T.pid is None or T.pid not in udp_pids(), T.pid)
    r = http("POST", T.base + "/lan/code", json={})
    check("lan_off: POST /lan/code while off -> 409 lan_off", r.status_code == 409 and jb(r).get("code") == "lan_off", r.status_code)

    # ---- bad inputs to POST /lan
    for body, label in (({"port": 80}, "port 80"), ({"enabled": "yes"}, "enabled as string"), ({"port": True}, "port true"),
                        ({"port": 70000}, "port 70000"), ({"name": 5}, "name number")):
        r = http("POST", T.base + "/lan", json=body)
        check("POST /lan rejects %s -> 400" % label, r.status_code == 400, r.status_code)
    r = http("POST", T.base + "/lan", data=b"{broken", headers={"Content-Type": "application/json"})
    check("POST /lan with broken JSON -> 400", r.status_code == 400, r.status_code)
    check("rejected updates changed nothing (still off)", get_lan(T).get("enabled") is False)

    # ---- B-04 turn on
    t0 = time.time()
    r = set_lan(T, enabled=True, port=L)
    st = jb(r)
    code0 = (st.get("pairing") or {}).get("code") or ""
    check("B-04a POST /lan enabled -> 200, listening true, 6-digit code", r.status_code == 200 and st.get("listening") is True and re.match(r"^\d{6}$", code0),
          "%.2fs" % (time.time() - t0))
    check("B-04b LAN port accepts connections", connect_code("127.0.0.1", L) == 0)
    pids = listening_pids(L)
    if T.pid is not None:
        check("B-04c netstat: LISTENING on the LAN port by the stub's own PID", T.pid in pids, "pids=%s" % pids)
    else:
        check("B-04c netstat: LISTENING on the LAN port", bool(pids), "pids=%s" % pids)
    rows = listening_rows(L)
    bound = st.get("bind")
    check("B-04d bind lists exactly this PC's Tailscale address(es) (GET /lan tailscale_addresses), never 0.0.0.0",
          isinstance(bound, list) and bool(bound) and bound == st.get("tailscale_addresses") and "0.0.0.0" not in bound, bound)
    check("B-04e netstat: LISTENING only on those addresses (%s), no 0.0.0.0 / :: row" % ",".join(map(str, bound or [])),
          bool(rows) and sorted(a for a, _ in rows) == sorted(bound or []) and not any(a in ("0.0.0.0", "::", "[::]") for a, _ in rows), rows)
    if ip2:
        check("B-04f the PC's other address %s refuses the link port (it is not bound there)" % ip2, connect_code(ip2, L) != 0)
    check("B-04g while on the server still owns no UDP socket (no discovery)", T.pid is None or T.pid not in udp_pids(), T.pid)
    check("B-07b loopback GET /health without token, LAN on -> 200", http("GET", T.base + "/health").status_code == 200)
    check("hello over the LAN listener needs no token and reveals only name + pairing_open",
          set(jb(http("GET", lurl(T, "/hello")))) == {"hoehwa", "name", "pairing_open"} and jb(http("GET", lurl(T, "/hello"))).get("pairing_open") is True)

    # ---- B-05 / B-06 token checks
    r = http("GET", lurl(T, "/health"))
    check("B-05 LAN /health without token -> 401 token_missing", r.status_code == 401 and jb(r).get("code") == "token_missing", r.status_code)
    fake = "hp1_" + "A" * 43
    r1 = http("GET", lurl(T, "/health"), token=fake)
    r2 = http("GET", lurl(T, "/health"), auth=fake)
    r3 = http("GET", lurl(T, "/health"), auth="")
    r4 = http("GET", lurl(T, "/health"), auth="Basic dXNlcjpwYXNz")
    r5 = http("GET", lurl(T, "/health"), auth="Bearer hp1_short")
    codes = [jb(x).get("code") for x in (r1, r2, r3, r4, r5)]
    check("B-06 wrong token / no scheme / empty / Basic / malformed -> all 401",
          all(x.status_code == 401 for x in (r1, r2, r3, r4, r5)) and codes[0] == "token_invalid" and codes[2] == "token_missing", codes)
    r = http("GET", lurl(T, "/health"), auth="bearer " + fake)
    check("scheme is case-insensitive but a wrong token is still 401 token_invalid", r.status_code == 401 and jb(r).get("code") == "token_invalid")
    check("loopback listener ignores a bad auth header -> 200",
          http("GET", T.base + "/health", auth="Bearer " + fake).status_code == 200)

    # ---- /pair format errors are not counted
    before = (get_lan(T).get("pairing") or {}).get("attempts_left")
    sends = [({"code": "abc123", "device_name": "x"}, 400, "code_format"), ({"code": "12345", "device_name": "x"}, 400, "code_format"),
             ({"code": "1234567", "device_name": "x"}, 400, "code_format"), ({"code": 482913, "device_name": "x"}, 400, "code_format"),
             ({"code": "０１２３４５", "device_name": "x"}, 400, "code_format"),
             ({"code": "123456"}, 400, "device_name_format"), ({"code": "123456", "device_name": ""}, 400, "device_name_format"),
             ({"code": "123456", "device_name": "  \n "}, 400, "device_name_format")]
    ok = True
    for body, status, cd in sends:
        r = http("POST", lurl(T, "/pair"), json=body)
        if r.status_code != status or jb(r).get("code") != cd:
            ok = False
            print("      unexpected:", body, r.status_code, jb(r))
    r = http("POST", lurl(T, "/pair"), data=b"nope", headers={"Content-Type": "application/json"})
    ok = ok and r.status_code == 400
    check("format errors (non-digit, 5/7 digits, number, full-width digits, no/blank name, broken JSON) -> 400 and NOT counted",
          ok and (get_lan(T).get("pairing") or {}).get("attempts_left") == before == 5, "attempts_left=%s" % before)

    # ---- B-08 six wrong codes
    real = (get_lan(T).get("pairing") or {}).get("code") or ""
    r = http("POST", lurl(T, "/pair"), json={"code": real + "\n", "device_name": "x"})
    check("S4a a valid code with a trailing newline is a format error (400), not accepted and not counted",
          r.status_code == 400 and jb(r).get("code") == "code_format" and (get_lan(T).get("pairing") or {}).get("attempts_left") == 5, r.status_code)
    wrong = "000000" if real != "000000" else "000001"
    statuses, lefts, cds = [], [], []
    for _ in range(6):
        r = http("POST", lurl(T, "/pair"), json={"code": wrong, "device_name": "Evil"})
        statuses.append(r.status_code)
        lefts.append(jb(r).get("attempts_left"))
        cds.append(jb(r).get("code"))
    check("B-08 six wrong codes -> [401,401,401,401,401,429]", statuses == [401] * 5 + [429], statuses)
    check("B-08b attempts_left 4,3,2,1,0 and the 6th is pair_locked", lefts[:5] == [4, 3, 2, 1, 0] and cds[5] == "pair_locked", (lefts, cds))
    pv = get_lan(T).get("pairing") or {}
    check("B-08c GET /lan: locked true, code hidden", pv.get("locked") is True and pv.get("code") is None and pv.get("active") is False, pv)
    check("hello during lock: pairing_open false", jb(http("GET", lurl(T, "/hello"))).get("pairing_open") is False)
    r = http("POST", lurl(T, "/pair"), json={"code": real, "device_name": "Pixel 8"})
    check("B-09a correct code after the lock -> still 429", r.status_code == 429 and jb(r).get("code") == "pair_locked", r.status_code)
    # ---- B-09b new code unlocks
    code1 = new_code(T)
    check("B-09b POST /lan/code unlocks and returns a 6-digit code + expires_in 300", bool(re.match(r"^\d{6}$", code1)) and (get_lan(T).get("pairing") or {}).get("locked") is False)
    r = http("POST", lurl(T, "/pair"), json={"code": code1, "device_name": "Pixel 8"})
    b = jb(r)
    tok1, dev1 = b.get("token", ""), b.get("device_id", "")
    check("B-09c correct new code -> 200 with a token hp1_<43>, device_id, server_name, port",
          r.status_code == 200 and TOKEN_RE.match(tok1) and re.match(r"^[0-9a-f]{8}$", dev1) and b.get("port") == L and b.get("server_name"), "token=%s" % mask(tok1))
    # ---- B-10a reuse
    r = http("POST", lurl(T, "/pair"), json={"code": code1, "device_name": "Pixel 8"})
    check("B-10a the same code a second time -> 410 no_active_code", r.status_code == 410 and jb(r).get("code") == "no_active_code", r.status_code)

    # ---- B-11 allowed requests, both addresses
    for host, label in [("127.0.0.1", "the Tailscale (here: loopback) address")]:
        h = http("GET", lurl(T, "/health", host), token=tok1)
        s = http("POST", lurl(T, "/stt", host), token=tok1, json={"lang": "en", "audio_b64": "AAAA"})
        m = http("GET", lurl(T, "/lan/me", host), token=tok1)
        stt_ok = (s.status_code == 200 and "text" in jb(s)) if stub else s.status_code not in (401, 403, 413, 429)    # real server: models may be missing
        check("B-11 valid token via %s: /health 200 ok, /stt %s, /lan/me 200 own id" % (label, "200 text" if stub else "reaches the app"),
              h.status_code == 200 and jb(h).get("ok") is True and stt_ok
              and m.status_code == 200 and jb(m).get("device_id") == dev1, (h.status_code, s.status_code, m.status_code))
    allowed = [("GET", "/curriculum", None), ("POST", "/tts", {"text": "hi", "lang": "en"}), ("GET", "/tts/voices", None),
               ("POST", "/score", {"lang": "en", "target": "hi", "audio_b64": "AAAA"}), ("POST", "/prosody", {"lang": "en", "text": "hi"}),
               ("POST", "/chat", {"lang": "en"}), ("POST", "/feedback", {"lang": "en"}), ("POST", "/fix", {"lang": "en"}),
               ("POST", "/lesson", {"lang": "en"}), ("POST", "/reading/analyze", {"lang": "en"}), ("POST", "/reading/gloss", {"lang": "en"}),
               ("GET", "/examples", None)]
    bad = []
    for m_, p_, body in allowed:
        r = http(m_, lurl(T, p_), token=tok1, json=body) if body is not None else http(m_, lurl(T, p_), token=tok1)
        if (r.status_code != 200) if stub else (r.status_code in (401, 403, 413, 429)):
            bad.append((m_, p_, r.status_code))
        if stub and p_ == "/tts" and not r.content.startswith(b"RIFF"):
            bad.append(("tts-not-wav",))
    check("every allow-list route %s through the gate" % ("answers 200 (TTS returns WAV)" if stub else "reaches the app (not 401/403/413/429)"), not bad, bad)

    # ---- B-11b English v1.1 routes: allowed with a token (the stub has no such route: 404 from the app is "through the gate"), 401 without
    v11 = [("GET", "/practice/ping", None), ("GET", "/practice/sentences?lang=en&n=3", None), ("GET", "/practice/phonemes", None),
           ("GET", "/practice/phoneme?id=TH", None), ("GET", "/missions", None), ("POST", "/missions/check", {"mission_id": "x", "turns": []}),
           ("POST", "/missions/judge", {"mission_id": "x", "turns": []})]
    bad = []
    for m_, p_, body in v11:
        with_tok = http(m_, lurl(T, p_), token=tok1, json=body) if body is not None else http(m_, lurl(T, p_), token=tok1)
        no_tok = http(m_, lurl(T, p_), json=body) if body is not None else http(m_, lurl(T, p_))
        if with_tok.status_code in (401, 403, 413, 429) or jb(with_tok).get("code") in ("lan_forbidden", "token_missing", "token_invalid"):
            bad.append(("with token", m_, p_, with_tok.status_code))
        if no_tok.status_code != 401 or jb(no_tok).get("code") != "token_missing":
            bad.append(("no token", m_, p_, no_tok.status_code))
    check("B-11b the 7 English v1.1 routes pass the gate with a token and answer 401 token_missing without one", not bad, bad)
    bad = []
    for m_, p_, body in [("POST", "/practice/ping", {}), ("GET", "/missions/check", None), ("GET", "/missions/judge", None), ("POST", "/missions", {}),
                         ("GET", "/practice/", None), ("GET", "/practice", None), ("GET", "/practice/phoneme/x", None), ("GET", "/missions/", None),
                         ("DELETE", "/missions", None)]:
        r = http(m_, lurl(T, p_), token=tok1, json=body) if body is not None else http(m_, lurl(T, p_), token=tok1)
        if r.status_code != 403 or jb(r).get("code") != "lan_forbidden":
            bad.append((m_, p_, r.status_code, jb(r).get("code")))
    check("B-11c near-miss paths and wrong methods next to the new routes are still 403 lan_forbidden", not bad, bad)

    # ---- B-12 forbidden
    forb = [("POST", "/mic/start", {}), ("GET", "/mic/devices", None), ("GET", "/mic/level", None), ("POST", "/mic/stop", {}), ("POST", "/mic/cancel", {}),
            ("POST", "/llm", {"provider": "ollama"}), ("GET", "/llm", None), ("POST", "/llm/test", {}), ("GET", "/llm/models", None),
            ("GET", "/docs", None), ("GET", "/openapi.json", None), ("GET", "/redoc", None), ("GET", "/debug/ping", None),
            ("GET", "/nope", None), ("GET", "/health/", None), ("HEAD", "/health", None), ("OPTIONS", "/health", None), ("DELETE", "/health", None),
            ("GET", "/HEALTH", None), ("POST", "/health", {})]
    bad = []
    for m_, p_, body in forb:
        r = http(m_, lurl(T, p_), token=tok1, json=body) if body is not None else http(m_, lurl(T, p_), token=tok1)
        if r.status_code != 403 or (m_ != "HEAD" and jb(r).get("code") != "lan_forbidden"):
            bad.append((m_, p_, r.status_code, jb(r).get("code")))
    r = http("GET", "http://127.0.0.1:%d//health" % L, token=tok1)
    if r.status_code != 403:
        bad.append(("GET", "//health", r.status_code))
    check("B-12 valid token on /mic/* /llm* /docs /openapi.json /debug/* unknown paths, odd methods, //health, /health/ -> 403 lan_forbidden", not bad, bad)
    if stub:    # never start the microphone / change the engine of a real server from a test
        check("B-12b the same forbidden routes work on the loopback listener (not broken for the PC app)",
              http("POST", T.base + "/mic/start", json={}).status_code == 200 and http("POST", T.base + "/llm", json={"provider": "x"}).status_code == 200
              and http("GET", T.base + "/docs").status_code == 200)
    else:
        check("B-12b /docs still works on the loopback listener of the real server", http("GET", T.base + "/docs").status_code == 200)

    # ---- B-13 admin from LAN
    ndev = len(get_lan(T).get("devices", []))
    adm = [("GET", "/lan", None), ("POST", "/lan", {"enabled": False}), ("POST", "/lan/code", {}), ("POST", "/lan/devices/revoke", {"all": True}),
           ("POST", "/lan/devices/revoke", {"id": dev1}), ("GET", "/lan/devices", None)]
    bad = []
    for m_, p_, body in adm:
        r = http(m_, lurl(T, p_), token=tok1, json=body) if body is not None else http(m_, lurl(T, p_), token=tok1)
        if r.status_code != 403 or jb(r).get("code") != "local_only":
            bad.append((m_, p_, r.status_code, jb(r).get("code")))
    check("B-13 valid token on /lan /lan/code /lan/devices/* via LAN -> 403 local_only", not bad, bad)
    after = get_lan(T)
    check("B-13b nothing changed by those calls (still on, same device count)", after.get("enabled") is True and len(after.get("devices", [])) == ndev, ndev)
    check("management without token on the LAN listener -> 401 (token is checked first)", http("GET", lurl(T, "/lan")).status_code == 401)

    # ---- m2: a valid token is only accepted as "Bearer <token>"
    variants = [("raw token without a scheme", tok1, 401), ("Token scheme", "Token " + tok1, 401), ("Bearer glued to the token", "Bearer" + tok1, 401),
                ("trailing junk after the token", "Bearer " + tok1 + " x", 401), ("Basic scheme", "Basic " + tok1, 401),
                ("Bearer (correct)", "Bearer " + tok1, 200), ("bearer lower case", "bearer " + tok1, 200), ("BEARER upper case", "BEARER " + tok1, 200)]
    bad = []
    for label, hv, want in variants:
        r = http("GET", lurl(T, "/health"), auth=hv)
        if r.status_code != want or (want == 401 and jb(r).get("code") != "token_invalid"):
            bad.append((label, r.status_code, jb(r).get("code")))
    check("m2 valid token: no scheme / Token / glued / trailing junk / Basic -> 401 token_invalid; Bearer in any letter case -> 200", not bad, bad)

    csrf_checks(T)
    acl_check(T)

    # ---- B-15 hygiene
    gl = http("GET", T.base + "/lan").text
    check("B-15a GET /lan body has no token_sha256 / hp1_ / the token", "token_sha256" not in gl and "hp1_" not in gl and tok1 not in gl)
    dv = (jb(http("GET", T.base + "/lan")).get("devices") or [{}])[0]
    check("B-15b device entry has id, name, created, last_seen, last_ip only", set(dv) == {"id", "name", "created", "last_seen", "last_ip"}, sorted(dv))
    if T.devfile:
        txt = open(T.devfile, "r", encoding="utf-8").read()
        sha = hashlib.sha256(tok1.encode()).hexdigest()
        data = json.loads(txt)
        check("B-15c device file: no token text, no 'hp1_', holds SHA-256 (64 hex) of the token", tok1 not in txt and "hp1_" not in txt and sha in txt
              and all(re.match(r"^[0-9a-f]{64}$", d["token_sha256"]) for d in data["devices"]) and data.get("version") == 1)
    else:
        skip("B-15c device file hygiene", "external server: file path unknown")

    # ---- B-22 proof
    key = bytes.fromhex(hashlib.sha256(tok1.encode()).hexdigest())
    nonce = "a1b2c3d4e5f60718"
    want = hmac.new(key, nonce.encode(), hashlib.sha256).hexdigest()
    r = http("POST", lurl(T, "/lan/proof"), json={"device_id": dev1, "nonce": nonce})
    check("B-22a /lan/proof without token returns the right HMAC-SHA256(key=SHA256(token), nonce)", r.status_code == 200 and hmac.compare_digest(jb(r).get("proof", ""), want))
    r = http("POST", lurl(T, "/lan/proof"), json={"device_id": dev1, "nonce": "ffffffff00000000"})
    check("B-22b a different nonce gives a different proof", r.status_code == 200 and jb(r).get("proof") != want)
    r = http("POST", lurl(T, "/lan/proof"), json={"device_id": "deadbeef", "nonce": nonce})
    check("B-22c unknown device_id -> 404 device_not_found", r.status_code == 404 and jb(r).get("code") == "device_not_found")
    r = http("POST", lurl(T, "/lan/proof"), json={"device_id": dev1, "nonce": "zz"})
    check("B-22d bad nonce -> 400", r.status_code == 400)
    r = http("POST", lurl(T, "/lan/proof"), json={"device_id": dev1, "nonce": nonce + "\n"})
    check("S4b a nonce with a trailing newline -> 400", r.status_code == 400)

    # ---- B-20 big bodies
    big = b"x" * (17 * 1024 * 1024)
    r = http("POST", lurl(T, "/stt"), token=tok1, data=big, headers={"Content-Type": "application/json"}, timeout=60)
    check("B-20a 17 MB POST /stt with token -> 413 too_large", r.status_code == 413 and jb(r).get("code") == "too_large", r.status_code)
    check("B-20b server still alive afterwards (/health 200 on both listeners)",
          http("GET", lurl(T, "/health"), token=tok1).status_code == 200 and http("GET", T.base + "/health").status_code == 200)

    def gen(n, chunk=65536):
        sent = 0
        while sent < n:
            yield b"y" * min(chunk, n - sent)
            sent += chunk
    r = http("POST", lurl(T, "/stt"), token=tok1, data=gen(17 * 1024 * 1024), headers={"Content-Type": "application/json"}, timeout=60)
    check("B-20c 17 MB sent chunked (no Content-Length) -> 413 too_large", r.status_code == 413 and jb(r).get("code") == "too_large", r.status_code)
    r = http("POST", lurl(T, "/stt"), token=tok1, data=b"z" * (5 * 1024 * 1024), headers={"Content-Type": "application/json"}, timeout=60)
    check("B-20d a legitimate 5 MB upload passes the gate (reaches the app; 200 or 422, not 413)", r.status_code in (200, 422), r.status_code)
    r = http("POST", lurl(T, "/stt"), data=big, headers={"Content-Type": "application/json"}, timeout=60)
    check("B-20e 17 MB without a token -> 401 token_missing (the answer reaches the client)", r.status_code == 401 and jb(r).get("code") == "token_missing", r.status_code)
    r = http("POST", lurl(T, "/pair"), data=b"q" * 5000, headers={"Content-Type": "application/json"})
    check("B-20f a 5 KB body to /pair (before login) -> 413", r.status_code == 413, r.status_code)

    # ---- B-18 / B-19 no discovery; keys of older versions are ignored
    r = set_lan(T, discovery=True, discovery_port=18776, allow_cgnat=True, allow_tailscale=True)
    st = get_lan(T)
    old_keys = ("discovery", "discovery_listening", "discovery_port", "allow_cgnat", "allow_tailscale", "addresses")
    check("B-18 POST /lan with the old keys discovery / discovery_port / allow_cgnat / allow_tailscale -> 200, ignored: GET /lan has none of them",
          r.status_code == 200 and not any(k in st for k in old_keys) and not any(k in jb(r) for k in old_keys), sorted(k for k in old_keys if k in st))
    check("B-19 ... and the server still owns no UDP socket", T.pid is None or T.pid not in udp_pids(), T.pid)
    r = set_lan(T, discovery_port="x", allow_tailscale="yes")
    check("a nonsense value for an old key is just ignored too (200)", r.status_code == 200)

    # ---- B-21 device limit
    toks = [(tok1, dev1)]
    while len(get_lan(T).get("devices", [])) < 8:
        t_, d_ = pair_token(T, "Phone %d" % len(toks))
        if not t_:
            break
        toks.append((t_, d_))
    check("pairing up to 8 devices works", len(get_lan(T).get("devices", [])) == 8, len(get_lan(T).get("devices", [])))
    code9 = new_code(T)
    r = http("POST", lurl(T, "/pair"), json={"code": code9, "device_name": "Ninth"})
    check("B-21 the 9th device -> 409 device_limit", r.status_code == 409 and jb(r).get("code") == "device_limit", r.status_code)
    check("B-21b the code was not used up by the refused 9th pairing", (get_lan(T).get("pairing") or {}).get("active") is True)

    # ---- B-14 revoke
    r = http("POST", T.base + "/lan/devices/revoke", json={"id": dev1})
    check("B-14a revoke by id -> 200 revoked 1", r.status_code == 200 and jb(r).get("revoked") == 1)
    r = http("GET", lurl(T, "/health"), token=tok1)
    check("B-14b the revoked token -> 401 token_invalid", r.status_code == 401 and jb(r).get("code") == "token_invalid")
    r = http("POST", T.base + "/lan/devices/revoke", json={"id": "00000000"})
    check("B-14c revoking an unknown id -> 404 device_not_found", r.status_code == 404 and jb(r).get("code") == "device_not_found")
    r = http("POST", T.base + "/lan/devices/revoke", json={})
    check("revoke with neither id nor all -> 400", r.status_code == 400)
    r = http("POST", lurl(T, "/pair"), json={"code": code9, "device_name": "Ninth"})
    tok9 = jb(r).get("token", "")
    check("after freeing a slot the 9th device can pair with the same code", r.status_code == 200 and TOKEN_RE.match(tok9), r.status_code)
    r = http("POST", lurl(T, "/lan/unpair"), token=tok9)
    check("B-14d /lan/unpair removes only the caller; its token then fails", r.status_code == 200 and jb(r).get("ok") is True
          and http("GET", lurl(T, "/health"), token=tok9).status_code == 401 and http("GET", lurl(T, "/health"), token=toks[1][0]).status_code == 200)
    check("/lan/me and /lan/unpair on the loopback listener (no device) -> 404", http("GET", T.base + "/lan/me").status_code == 404
          and http("POST", T.base + "/lan/unpair").status_code == 404)

    # ---- B-17 off / on again
    keep_tok = toks[1][0]
    t0 = time.time()
    r = set_lan(T, enabled=False)
    closed, dt = wait_closed("127.0.0.1", L, 3.0)
    check("B-17a POST /lan enabled=false -> LAN port closes within 3 s", r.status_code == 200 and closed and dt <= 3.0, "%.2fs" % (time.time() - t0))
    st = get_lan(T)
    check("B-17b off: listening false, bind [], code hidden, devices kept", st.get("listening") is False and st.get("bind") == []
          and (st.get("pairing") or {}).get("code") is None and len(st.get("devices", [])) >= 1)
    check("B-17c after turning off the server owns no UDP socket either", T.pid is None or T.pid not in udp_pids(), T.pid)
    if ip2:
        check("B-17e non-loopback address refuses too", connect_code(ip2, L) != 0)
    check("B-07c loopback /health without token while LAN is off again -> 200", http("GET", T.base + "/health").status_code == 200)
    r = set_lan(T, enabled=True)
    check("B-17f turning it on again -> 200 listening", r.status_code == 200 and jb(r).get("listening") is True)
    check("B-17g an old token works again after off/on", http("GET", lurl(T, "/health"), token=keep_tok).status_code == 200)
    check("a new code was made for the new session", bool((get_lan(T).get("pairing") or {}).get("code")))

    # ---- B-23 port busy
    set_lan(T, enabled=False)
    busy_port = pick()
    blocker = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    blocker.bind(("127.0.0.1", busy_port))    # the address the link binds to (hook), so the OS really sees a conflict
    blocker.listen(1)
    try:
        r = set_lan(T, enabled=True, port=busy_port)
        st = get_lan(T)
        check("B-23a port taken by another program -> 409 lan_port_busy", r.status_code == 409 and jb(r).get("code") == "lan_port_busy", (r.status_code, jb(r).get("error")))
        check("B-23b afterwards: enabled false, listening false, loopback /health still 200",
              st.get("enabled") is False and st.get("listening") is False and http("GET", T.base + "/health").status_code == 200)
        set_lan(T, enabled=True, port=L)
        r = set_lan(T, port=busy_port)
        st = get_lan(T)
        check("B-23c changing the port to a busy one while on -> 409 and the old listener keeps running",
              r.status_code == 409 and st.get("enabled") is True and st.get("listening") is True and st.get("port") == L
              and http("GET", lurl(T, "/health"), token=keep_tok).status_code == 200)
    finally:
        blocker.close()
        release(busy_port)
    newp = pick()
    r = set_lan(T, port=newp)
    st = jb(r)
    time.sleep(0.3)
    check("port change to a free port while on: new port serves, old port closed", r.status_code == 200 and st.get("port") == newp
          and http("GET", "http://127.0.0.1:%d/health" % newp, token=keep_tok).status_code == 200 and connect_code("127.0.0.1", L) != 0)
    set_lan(T, port=L)
    release(newp)
    r = set_lan(T, enabled=False)
    check("core scenarios end with the link off and the port closed", r.status_code == 200 and wait_closed("127.0.0.1", L, 3.0)[0])


def scenario_ttl():
    print("\n== B-10b code expiry (HOEHWA_TEST_HOOKS=1 HOEHWA_LAN_CODE_TTL=2)")
    T = Stub("ttl", env={"HOEHWA_TEST_HOOKS": "1", "HOEHWA_LAN_CODE_TTL": "2"}).start()
    try:
        r = set_lan(T, enabled=True, port=T.lan_port)
        pv = jb(r).get("pairing") or {}
        code = pv.get("code") or ""
        check("a 2-second code: expires_in <= 2", pv.get("active") is True and 1 <= pv.get("expires_in", 99) <= 2, pv.get("expires_in"))
        time.sleep(3.0)
        check("after 3 s hello says pairing_open false", jb(http("GET", lurl(T, "/hello"))).get("pairing_open") is False)
        r = http("POST", lurl(T, "/pair"), json={"code": code, "device_name": "Late"})
        check("B-10b the expired code -> 410 no_active_code", r.status_code == 410 and jb(r).get("code") == "no_active_code", r.status_code)
        check("an expired code does not count as a failed attempt (not locked)", (get_lan(T).get("pairing") or {}).get("locked") is False)
        r = http("POST", T.base + "/lan/code", json={})
        check("POST /lan/code gives expires_in 2 in test-hook mode", jb(r).get("expires_in") == 2)
        r = http("POST", T.base + "/lan/code", json={"cancel": True})
        check("POST /lan/code cancel -> ok and the code is gone", jb(r).get("ok") is True and (get_lan(T).get("pairing") or {}).get("active") is False)
    finally:
        T.stop()
        T.release_ports()


def scenario_restart():
    print("\n== B-16 persistence and broken device file")
    T = Stub("persist").start()
    tok = ""
    try:
        set_lan(T, enabled=True, port=T.lan_port)
        tok, dev = pair_token(T)
        check("paired before the restart", bool(tok))
    finally:
        T.stop()
    closed, _ = wait_closed("127.0.0.1", T.lan_port, 3.0)
    check("killed stub: its LAN port is gone", closed)
    T.enabled = True      # like a saved "enabled": true
    T.start(keep_ports=True)
    try:
        st = get_lan(T)
        check("restart with enabled=true: listening at boot without any POST", st.get("listening") is True and st.get("enabled") is True)
        check("B-16a the same token still works after a restart", http("GET", lurl(T, "/health"), token=tok).status_code == 200)
    finally:
        T.stop()
    with open(T.devfile, "w", encoding="utf-8") as f:
        f.write("{broken")
    T.start(keep_ports=True)
    try:
        r = http("GET", T.base + "/health")
        check("B-16b broken device file: server starts and answers", r.status_code == 200)
        check("B-16c old token -> 401 token_invalid", http("GET", lurl(T, "/health"), token=tok).status_code == 401 and
              jb(http("GET", lurl(T, "/health"), token=tok)).get("code") == "token_invalid")
        check("B-16d the broken file was moved to *.bad", os.path.exists(T.devfile + ".bad"))
        check("device list is empty after the reset", get_lan(T).get("devices") == [])
        tok2, _ = pair_token(T)
        check("pairing works again after the reset", bool(tok2) and http("GET", lurl(T, "/health"), token=tok2).status_code == 200)
    finally:
        T.stop()
    with open(T.devfile, "w", encoding="utf-8") as f:
        json.dump({"version": 1, "devices": "not-a-list"}, f)
    T.start(keep_ports=True)
    try:
        check("wrong-shaped (valid JSON) device file is also reset, not trusted", get_lan(T).get("devices") == [] and
              http("GET", lurl(T, "/health"), token=tok).status_code == 401)
    finally:
        T.stop()
        T.release_ports()
    with open(T.devfile, "w", encoding="utf-8") as f:
        json.dump({"version": 1, "devices": [{"id": "zz", "name": "x", "token_sha256": "nothex"}, {"id": "0a0b0c0d", "name": "ok", "token_sha256": "a" * 64}]}, f)
    T2 = Stub("persist", enabled=False).start()
    try:
        devs = get_lan(T2).get("devices", [])
        check("invalid entries in a device file are skipped, valid ones kept", [d["id"] for d in devs] == ["0a0b0c0d"], devs)
    finally:
        T2.stop()
        T2.release_ports()


def scenario_rate():
    print("\n== rate limit for bad tokens")
    T = Stub("rate").start()
    try:
        set_lan(T, enabled=True, port=T.lan_port)
        tok, _ = pair_token(T)
        codes = []
        for i in range(32):
            r = http("GET", lurl(T, "/health"), token="hp1_" + ("%043d" % i))
            codes.append(r.status_code)
        check("30 bad tokens from one IP -> 401, then 429 rate_limited", codes[:30] == [401] * 30 and 429 in codes[30:], codes[28:])
        r = http("GET", lurl(T, "/health"), token=tok)
        check("while limited even a valid token gets 429 (10-minute window)", r.status_code == 429 and jb(r).get("code") == "rate_limited", r.status_code)
        check("/hello and /pair are not rate limited (pairing has its own lock)", http("GET", lurl(T, "/hello")).status_code == 200
              and http("POST", lurl(T, "/pair"), json={"code": "000000", "device_name": "x"}).status_code in (401, 410, 429))
        check("loopback listener unaffected", http("GET", T.base + "/health").status_code == 200)
        # re-pairing from the rate-limited address clears its bad-token record: the NEW token works at once (not 429 for 10 minutes)
        tok2, _ = pair_token(T, name="Pixel 8 again")
        r = http("GET", lurl(T, "/health"), token=tok2) if tok2 else None
        check("after 30 bad tokens, a successful re-pairing from that IP -> new token gets 200 (not 429)",
              bool(tok2) and r is not None and r.status_code == 200, r.status_code if r is not None else "pairing failed")
    finally:
        T.stop()
        T.release_ports()


def scenario_core_stub(ip2):
    T = Stub("core").start()      # the link listens on the hook's Tailscale address 127.0.0.1: tests never bind 0.0.0.0
    try:
        core(T, ip2)
    finally:
        T.stop()
        T.release_ports()
    return T
# ----------------------------------------------------------------------------------------------
# security fixes: S1 source filter, S2 CSRF / rebinding, S3 network safety, S4 small things
# ----------------------------------------------------------------------------------------------
class FakeTransport:
    def __init__(self, host):
        self.host = host
        self.aborted = False

    def get_extra_info(self, name):
        return (self.host, 5555) if name == "peername" else None

    def abort(self):
        self.aborted = True

    def close(self):
        pass


def gate_call(ip, method="GET", path="/hello", headers=None, server=None):
    """run LanGate in-process with a made-up scope['client'] (and scope['server'] = this PC's address the connection came in on)
    -> (app_called, messages sent to the client)"""
    import asyncio
    called, sent = [], []

    async def app(scope, receive, send):
        called.append(scope)
        await send({"type": "http.response.start", "status": 200, "headers": []})
        await send({"type": "http.response.body", "body": b"{}"})

    async def send(m):
        sent.append(m)

    async def receive():
        return {"type": "http.request", "body": b"", "more_body": False}

    scope = {"type": "http", "method": method, "path": path, "client": (ip, 1234), "headers": headers or []}
    if server is not None:
        scope["server"] = server
    asyncio.run(lan.LanGate(app)(scope, receive, send))
    return bool(called), sent


def unit_security():
    print("\n== security helpers (in-process)")
    allowed = ["127.0.0.1", "127.5.5.5", "::1", "::ffff:127.0.0.1", "100.64.0.1", "100.101.102.103", "100.127.255.255", "fd7a:115c:a1e0::1",
               "fd7a:115c:a1e0:ffff::9", "::ffff:100.64.0.9"]
    denied = ["10.1.2.3", "172.16.0.1", "172.31.255.255", "192.168.1.1", "169.254.9.9", "fe80::1", "fd12:3456::1", "fc00::1", "fd7a:115c:a1e1::1",
              "::ffff:192.168.0.2", "100.63.255.255", "100.128.0.1", "8.8.8.8", "175.212.223.8", "172.32.0.1", "0.0.0.0", "2001:db8::1",
              "2606:4700::1111", "::ffff:8.8.8.8", "fec0::1", "ff02::1", "junk", ""]
    bad_a = [x for x in allowed if not lan._source_allowed(x)]
    bad_d = [x for x in denied if lan._source_allowed(x)]
    check("S1a source filter: loopback and Tailscale only - 127/8, ::1, 100.64.0.0/10 (both edges), fd7a:115c:a1e0::/48, mapped forms - are allowed", not bad_a, bad_a)
    check("S1b source filter: private 10/8 172.16/12 192.168/16, link-local, other ULA (fd12::, fc00::), 100.63.x / 100.128.x, public, multicast, junk and empty are denied",
          not bad_d, bad_d)
    silent_ips = ("192.168.0.7", "10.0.0.5", "172.20.1.1", "169.254.1.1", "fd00::1", "fe80::2", "8.8.8.8", "175.212.223.8", "2606:4700::1111")
    served_ips = ("127.0.0.1", "100.64.0.9", "100.101.102.103", "fd7a:115c:a1e0::5")
    res = {ip: gate_call(ip) for ip in silent_ips + served_ips}
    silent = all(not res[ip][0] and res[ip][1] == [] for ip in silent_ips)
    served = all(res[ip][0] for ip in served_ips)
    check("S1d LanGate with a fake scope['client']: private / link-local / other-ULA / public sources get NO answer and never reach the app; loopback and Tailscale do",
          silent and served, {ip: (v[0], len(v[1])) for ip, v in res.items()})
    called, sent = gate_call("192.168.0.7", "POST", "/pair")
    called2, sent2 = gate_call("8.8.8.8", "GET", "/health")
    check("S1e a private-LAN or public source cannot reach /pair or any other path (no answer, no lock side effect)",
          not called and not sent and not called2 and not sent2 and lan.S.fails == 0 and lan.S.locked is False)
    called, sent = gate_call("100.101.102.103", "GET", "/health")
    check("S1f a Tailscale source without a token still gets 401 (the filter is in front of the rest, not instead of it)",
          not called and sent and sent[0]["status"] == 401)
    P = lan._make_protocol()
    aborted = {}
    for ip in ("192.168.0.9", "10.0.0.2", "169.254.4.4", "8.8.8.8", "127.0.0.1", "100.101.102.103"):
        pr = P.__new__(P)
        t = FakeTransport(ip)
        try:
            pr.connection_made(t)
        except AttributeError:
            pass          # it went on to the normal setup instead of dropping the connection (the real init state is not built here)
        aborted[ip] = t.aborted
    check("S1h the listener's protocol aborts a connection from a private-LAN / link-local / public address before reading anything",
          aborted["192.168.0.9"] and aborted["10.0.0.2"] and aborted["169.254.4.4"] and aborted["8.8.8.8"], aborted)
    check("S1i ... and does not abort a loopback or Tailscale address", not aborted["127.0.0.1"] and not aborted["100.101.102.103"], aborted)
    check("S4c regexes use \\Z: a code / nonce / token with a trailing newline does not match",
          not lan.CODE_RE.match("123456\n") and lan.CODE_RE.match("123456") and not lan.NONCE_RE.match("a1b2c3d4\n")
          and not lan.TOKEN_RE.match("Bearer hp1_" + "A" * 43 + "\n") and not lan.ID_RE.match("a1b2c3d4\n") and not lan.HASH_RE.match("a" * 64 + "\n"))
    saved_env = {k: os.environ.get(k) for k in ("HOEHWA_TEST_HOOKS", "HOEHWA_LAN_CODE_TTL", "HOEHWA_LAN_ASSUME_TAILSCALE")}
    try:
        os.environ.pop("HOEHWA_TEST_HOOKS", None)
        os.environ["HOEHWA_LAN_CODE_TTL"] = "2"
        os.environ["HOEHWA_LAN_ASSUME_TAILSCALE"] = "127.0.0.1"
        a = (lan._code_ttl(), lan._fake_tailscale())
        os.environ["HOEHWA_TEST_HOOKS"] = "1"
        b = (lan._code_ttl(), lan._fake_tailscale())
        check("HOEHWA_LAN_CODE_TTL / HOEHWA_LAN_ASSUME_TAILSCALE are ignored without HOEHWA_TEST_HOOKS=1 and read with it",
              a == (300.0, None) and b == (2.0, ["127.0.0.1"]), (a, b))
    finally:
        for k, v in saved_env.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
    lan.S.bad_tokens.clear()
    for i in range(5000):
        lan._note_bad_token("10.%d.%d.1" % (i // 256, i % 256))
    for _ in range(200):
        lan._note_bad_token("10.99.99.99")
    check("S4d the bad-token table is capped (<= %d addresses, <= %d entries per address) after 5000 sources" % (lan.BAD_TOKEN_MAX_IPS, lan.RATE_FAILS * 2),
          len(lan.S.bad_tokens) <= lan.BAD_TOKEN_MAX_IPS and max(len(q) for q in lan.S.bad_tokens.values()) <= lan.RATE_FAILS * 2, len(lan.S.bad_tokens))
    lan.S.bad_tokens.clear()
def csrf_checks(T):
    """S2: management endpoints refuse a web page's request (Origin / Host / Content-Type); the PC app's own style still works"""
    port = T.http_port
    url = T.base + "/lan"
    new_code(T)            # an active code, so "cancel" and the lock state are observable
    set_lan(T, name="CsrfOrig")
    cur = get_lan(T)
    same = json.dumps({"name": "CsrfOrig"})       # a body that changes nothing if it were accepted
    flip = json.dumps({"name": "CsrfFlipped"})
    evil_all = requests.post(url, data=flip, headers={"Content-Type": "text/plain", "Origin": "http://evil.example", "Host": "evil.example:%d" % port}, timeout=15)
    check("S2a POST /lan with Content-Type text/plain + Origin evil + Host evil + body {name:flipped} -> 403 bad_origin",
          evil_all.status_code == 403 and jb(evil_all).get("code") == "bad_origin", (evil_all.status_code, jb(evil_all).get("code")))
    check("S2b ... and the setting did not change", get_lan(T).get("name") == "CsrfOrig" == cur.get("name"))
    J = {"Content-Type": "application/json"}
    bad_cases = [
        ("only Origin evil", J, {"Origin": "http://evil.example"}),
        ("Origin null", J, {"Origin": "null"}),
        ("only Host evil", J, {"Host": "evil.example:%d" % port}),
        ("Host 127.0.0.1.evil.example", J, {"Host": "127.0.0.1.evil.example:%d" % port}),
        ("Host evil without port", J, {"Host": "evil.example"}),
        ("only Content-Type text/plain", {"Content-Type": "text/plain"}, {}),
        ("only Content-Type form-urlencoded", {"Content-Type": "application/x-www-form-urlencoded"}, {}),
        ("no Content-Type", {}, {}),
        ("loopback Origin on another port", J, {"Origin": "http://127.0.0.1:1"}),
        ("localhost Origin but 127.0.0.1 Host", J, {"Origin": "http://localhost:%d" % port}),
        ("https Origin", J, {"Origin": "https://127.0.0.1:%d" % port}),
    ]
    bad = []
    for label, h1, h2 in bad_cases:
        hh = dict(h1)
        hh.update(h2)
        r = requests.post(url, data=same.encode(), headers=hh, timeout=15)
        if r.status_code != 403 or jb(r).get("code") != "bad_origin":
            bad.append((label, r.status_code, jb(r).get("code")))
    check("S2c each of Origin evil / null / other port / https, Host evil / suffix trick, Content-Type text/plain / form / none alone -> 403 bad_origin", not bad, bad)
    ok_cases = [
        ("PC app style (JSON, Host 127.0.0.1:port, no Origin)", J, {}),
        ("same-origin Origin", J, {"Origin": "http://127.0.0.1:%d" % port}),
        ("localhost Host + localhost Origin", J, {"Host": "localhost:%d" % port, "Origin": "http://localhost:%d" % port}),
        ("[::1] Host", J, {"Host": "[::1]:%d" % port}),
        ("JSON with charset", {"Content-Type": "application/json; charset=utf-8"}, {}),
        ("upper-case JSON type", {"Content-Type": "Application/JSON"}, {}),
    ]
    bad = []
    for label, h1, h2 in ok_cases:
        hh = dict(h1)
        hh.update(h2)
        r = requests.post(url, data=same.encode(), headers=hh, timeout=15)
        if r.status_code != 200:
            bad.append((label, r.status_code, jb(r).get("code")))
    check("S2d the legitimate shapes still work: no Origin (what Godot's HTTPRequest sends), same-origin, localhost, [::1], JSON with charset", not bad, bad)
    reads = [requests.get(url, headers={"Host": "evil.example:%d" % port}, timeout=15), requests.get(url, headers={"Origin": "http://evil.example"}, timeout=15)]
    check("S2e GET /lan (it shows the pairing code) with Host evil or Origin evil -> 403 (DNS rebinding cannot read it)",
          all(r.status_code == 403 and jb(r).get("code") == "bad_origin" and "code" not in (jb(r).get("pairing") or {}) for r in reads))
    ndev = len(get_lan(T).get("devices", []))
    others = [("/lan/code", {}), ("/lan/code", {"cancel": True}), ("/lan/devices/revoke", {"all": True})]
    bad = []
    for path, body in others:
        for hh in ({"Content-Type": "application/json", "Origin": "http://evil.example"}, {"Content-Type": "text/plain"},
                   {"Content-Type": "application/json", "Host": "evil.example:%d" % port}):
            r = requests.post(T.base + path, data=json.dumps(body).encode(), headers=hh, timeout=15)
            if r.status_code != 403 or jb(r).get("code") != "bad_origin":
                bad.append((path, sorted(hh), r.status_code))
    check("S2f /lan/code, /lan/code cancel and /lan/devices/revoke {all} are refused the same way; nothing was revoked or cancelled",
          not bad and len(get_lan(T).get("devices", [])) == ndev and (get_lan(T).get("pairing") or {}).get("active") is True, bad)
    check("S2g the public endpoint /hello is not affected by Host / Origin (it reveals nothing private)",
          requests.get(T.base + "/hello", headers={"Host": "evil.example", "Origin": "http://evil.example"}, timeout=15).status_code == 200)


def acl_check(T):
    """S4: the device file is readable by the current Windows user only (best effort; icacls)"""
    if os.name != "nt" or not T.devfile or not os.path.exists(T.devfile):
        note("S4e device-file ACL not checked", "not Windows or the file path is unknown")
        return
    user = os.environ.get("USERNAME", "")
    r = subprocess.run(["icacls", T.devfile], capture_output=True, text=True, errors="replace")
    aces = re.findall(r"(\S+):\(", r.stdout.replace(T.devfile, ""))
    check("S4e the device file's ACL has exactly one entry and it is the current user (no Everyone / Users / inherited admins)",
          user and len(aces) == 1 and aces[0].lower().endswith(user.lower()), "aces=%s" % aces)
    check("S4f the file is still readable and still valid JSON by its owner", json.load(open(T.devfile, "r", encoding="utf-8")).get("version") == 1)


NO_TAILSCALE_TEXT = "이 PC에서 Tailscale이 꺼져 있거나 설치되지 않았어요. tailscale.com 에서 설치하고 휴대폰과 같은 구글 계정으로 로그인한 뒤 다시 켜 주세요."


def scenario_netsafe():
    print("\n== S3 the link needs a Tailscale address (hook HOEHWA_LAN_ASSUME_TAILSCALE: '' = none, 127.0.0.1 = the loopback stands in)")
    T = Stub("net0", env={"HOEHWA_LAN_ASSUME_TAILSCALE": ""}).start()
    try:
        st = get_lan(T)
        check("S3a no Tailscale address: GET /lan says network_safe false, network_reason = the agreed Korean text, tailscale_addresses [], no addresses / allow_* / discovery keys",
              st.get("network_safe") is False and st.get("network_reason") == NO_TAILSCALE_TEXT and st.get("tailscale_addresses") == []
              and not any(k in st for k in ("addresses", "allow_tailscale", "allow_cgnat", "discovery", "discovery_port")), st.get("network_reason", "")[:30])
        r = set_lan(T, enabled=True, port=T.lan_port)
        check("S3b POST /lan {enabled:true} -> 409 no_tailscale with the agreed Korean message (install, same Google account, turn on again)",
              r.status_code == 409 and jb(r).get("code") == "no_tailscale" and jb(r).get("error") == NO_TAILSCALE_TEXT, (r.status_code, jb(r).get("code")))
        st = get_lan(T)
        check("S3c nothing was started: enabled false, listening false, bind [], LAN port closed, the server owns no UDP socket, no code",
              st.get("enabled") is False and st.get("listening") is False and st.get("bind") == [] and connect_code("127.0.0.1", T.lan_port) != 0
              and T.pid not in udp_pids() and (st.get("pairing") or {}).get("code") is None and not listening_rows(T.lan_port))
        r = set_lan(T, name="Other PC")
        check("S3d other settings can still be changed while the link is off (200)", r.status_code == 200 and jb(r).get("name") == "Other PC")
        r = http("POST", T.base + "/lan/code", json={})
        check("S3e /lan/code while off -> 409 lan_off", r.status_code == 409 and jb(r).get("code") == "lan_off")
        text = http("GET", T.base + "/lan").text + r.text + http("GET", T.base + "/hello").text
        ips = re.findall(r"\b\d{1,3}(?:\.\d{1,3}){3}\b", text)
        check("S3f no address that is not loopback / Tailscale appears in any response", all(lan._source_allowed(i) for i in ips), ips)
    finally:
        T.stop()
        T.release_ports()
    T = Stub("net1").start()
    try:
        st0 = get_lan(T)
        r = set_lan(T, enabled=True, port=T.lan_port)
        j = jb(r)
        check("S3g with a Tailscale address (hook 127.0.0.1): network_safe true, tailscale_addresses ['127.0.0.1'], the link turns on and binds exactly there",
              st0.get("network_safe") is True and st0.get("tailscale_addresses") == ["127.0.0.1"] and r.status_code == 200 and j.get("listening") is True
              and j.get("bind") == ["127.0.0.1"], (st0.get("network_safe"), j.get("bind")))
        rows = listening_rows(T.lan_port)
        check("S3h netstat shows the link LISTENING on 127.0.0.1:port only - not 0.0.0.0, not ::", [a for a, _ in rows] == ["127.0.0.1"] and all(pid == T.pid for _, pid in rows), rows)
        ip2 = own_ip()
        if ip2:
            check("S3h2 this PC's own other address %s refuses the link port" % ip2, connect_code(ip2, T.lan_port) != 0)
        r = set_lan(T, name="Changed")
        check("S3i changing a setting while it is already on is not blocked (200) and the listener keeps its address", r.status_code == 200 and jb(r).get("bind") == ["127.0.0.1"])
    finally:
        T.stop()
        T.release_ports()
    have = bool(lan.tailscale_addresses(fresh=True))       # this test process has no hooks set: the real adapters
    T = Stub("net2", no_hooks=True).start()          # no hooks at all: the real answer for this PC
    try:
        st0 = get_lan(T)
        r = set_lan(T, enabled=True, port=T.lan_port)
        j = jb(r)
        check("S3j WITHOUT the test hooks the real adapters decide (%s on this PC)" % ("a Tailscale address exists -> allowed, bound there only" if have else "no Tailscale address -> 409 no_tailscale"),
              st0.get("network_safe") is have and r.status_code == (200 if have else 409) and (have or (j.get("code") == "no_tailscale" and j.get("error") == NO_TAILSCALE_TEXT))
              and (have or (not listening_rows(T.lan_port) and connect_code("127.0.0.1", T.lan_port) != 0)),
              (have, st0.get("network_safe"), r.status_code, j.get("code")))
        if have:
            check("S3j2 (Tailscale present) the link is bound to the Tailscale address(es) only", not any(a in ("0.0.0.0", "::", "127.0.0.1") for a, _ in listening_rows(T.lan_port)), listening_rows(T.lan_port))
            set_lan(T, enabled=False)
    finally:
        T.stop()
        T.release_ports()
    T = Stub("net3", env={"HOEHWA_LAN_ASSUME_TAILSCALE": ""}, enabled=True).start()
    try:
        st = get_lan(T)
        check("S3k saved enabled=true but no Tailscale address at boot: stays off, says why (the Korean text), port closed",
              st.get("enabled") is False and st.get("listening") is False and st.get("error") == NO_TAILSCALE_TEXT and connect_code("127.0.0.1", T.lan_port) != 0)
    finally:
        T.stop()
        T.release_ports()
    T = Stub("net4", env={"HOEHWA_LAN_ASSUME_TAILSCALE": "127.0.0.1,127.0.0.2"}).start()
    try:
        r = set_lan(T, enabled=True, port=T.lan_port)
        j = jb(r)
        rows = listening_rows(T.lan_port)
        check("S3l two Tailscale addresses: the link binds both (and only those): bind lists them, netstat has exactly those two rows, both accept, 0.0.0.0 does not appear",
              r.status_code == 200 and sorted(j.get("bind", [])) == ["127.0.0.1", "127.0.0.2"] and sorted(a for a, _ in rows) == ["127.0.0.1", "127.0.0.2"]
              and connect_code("127.0.0.1", T.lan_port) == 0 and connect_code("127.0.0.2", T.lan_port) == 0, (j.get("bind"), rows))
        check("S3l2 /hello answers through the second address as well", http("GET", lurl(T, "/hello", "127.0.0.2")).status_code == 200)
    finally:
        T.stop()
        T.release_ports()
    T = Stub("net5", env={"HOEHWA_LAN_ASSUME_TAILSCALE": "100.101.102.103"}).start()
    try:
        r = set_lan(T, enabled=True, port=T.lan_port)
        check("S3m a 'Tailscale address' that is not on this PC (bind fails: address not available) -> 409 no_tailscale, nothing listens, link stays off",
              r.status_code == 409 and jb(r).get("code") == "no_tailscale" and connect_code("127.0.0.1", T.lan_port) != 0 and get_lan(T).get("enabled") is False,
              (r.status_code, jb(r).get("code")))
    finally:
        T.stop()
        T.release_ports()
def _raw(port, payload, wait):
    """send raw bytes, then read until the server closes or `wait` seconds pass -> (bytes, seconds)"""
    t0 = time.time()
    s = socket.create_connection(("127.0.0.1", port), timeout=5)
    s.settimeout(0.5)
    data = b""
    try:
        s.sendall(payload)
        while time.time() - t0 < wait:
            try:
                chunk = s.recv(4096)
            except socket.timeout:
                continue
            except OSError:
                break
            if not chunk:
                break
            data += chunk
    finally:
        s.close()
    return data, time.time() - t0


def scenario_slow():
    print("\n== S4 slow senders (timeouts shortened with the test hooks: 2 s before login, 3 s for an upload)")
    T = Stub("slow", env={"HOEHWA_LAN_PREAUTH_TIMEOUT": "2", "HOEHWA_LAN_BODY_TIMEOUT": "3"}).start()
    try:
        set_lan(T, enabled=True, port=T.lan_port)
        tok, _ = pair_token(T)
        head = b"POST /pair HTTP/1.1\r\nHost: x\r\nContent-Type: application/json\r\nContent-Length: 60\r\n\r\n"
        data, dt = _raw(T.lan_port, head + b'{"code"', 9)
        check("S4g /pair body that never completes -> 408 request_timeout after ~2 s (not held open)", b" 408 " in data and b"request_timeout" in data and 1.5 <= dt <= 6, "%.1fs" % dt)
        head = ("POST /stt HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer %s\r\nContent-Type: application/json\r\nContent-Length: 100000\r\n\r\n" % tok).encode()
        data, dt = _raw(T.lan_port, head + b"x" * 10, 12)
        check("S4h an authenticated upload that stalls -> 408 after its (longer) limit ~3 s", b" 408 " in data and 2.5 <= dt <= 8, "%.1fs" % dt)
        head = b"POST /stt HTTP/1.1\r\nHost: x\r\nContent-Type: application/json\r\nContent-Length: 1000\r\n\r\n"
        data, dt = _raw(T.lan_port, head, 12)
        check("S4i a refused request (no token) whose body never arrives is answered 401 and closed after ~2 s", b" 401 " in data and dt <= 7, "%.1fs" % dt)
        check("S4j the server is fine afterwards (valid token /health 200 on the link, loopback 200)",
              http("GET", lurl(T, "/health"), token=tok).status_code == 200 and http("GET", T.base + "/health").status_code == 200)
    finally:
        T.stop()
        T.release_ports()



def scenario_acl():
    print("\n== S4 device-file ACL uses the process account, not the USERNAME variable")
    if os.name != "nt":
        note("S4k ACL scenario not run", "not Windows")
        return
    T = Stub("acl", env={"USERNAME": "Administrator"}).start()      # a wrong USERNAME must not lock the real user out
    try:
        set_lan(T, enabled=True, port=T.lan_port)
        tok, dev = pair_token(T)
        try:
            data = json.load(open(T.devfile, "r", encoding="utf-8"))
            readable = data.get("version") == 1 and len(data.get("devices", [])) == 1
        except Exception as e:
            readable = False
            print("      read failed:", repr(e)[:80])
        r = subprocess.run(["icacls", T.devfile], capture_output=True, text=True, errors="replace")
        aces = re.findall(r"(\S+):\(", r.stdout.replace(T.devfile, ""))
        real = os.environ.get("USERNAME", "")
        check("S4k with USERNAME=Administrator the device file is still readable by the real account, and the only ACE is that account",
              bool(tok) and readable and len(aces) == 1 and aces[0].lower().endswith(real.lower()) and "administrator" not in aces[0].lower(), "aces=%s" % aces)
    finally:
        T.stop()
    T.enabled = True
    T.start(keep_ports=True)
    try:
        check("S4l ... and after a restart the token is still accepted (the file is not treated as broken, no .bad)",
              http("GET", lurl(T, "/health"), token=tok).status_code == 200 and not os.path.exists(T.devfile + ".bad"))
    finally:
        T.stop()
        T.release_ports()


def scenario_hdr():
    print("\n== S4 header-phase slowloris (default limit 10 s, headers capped at 16 KB)")
    T = Stub("hdr").start()
    try:
        set_lan(T, enabled=True, port=T.lan_port)
        tok, _ = pair_token(T)
        data, dt = _raw(T.lan_port, b"GET /hello HTTP/1.1\r\nHost: x\r\nX-A: ", 15)
        check("S4m a connection that sends half a header and stalls is closed by the server after ~10 s (not held open)", data == b"" and 8.0 <= dt <= 12.5, "%.1fs" % dt)
        s1 = socket.create_connection(("127.0.0.1", T.lan_port), timeout=5)
        s1.settimeout(5)
        s1.sendall(b"GET /hello HTTP/1.1\r\nHost: x\r\n")
        time.sleep(1.5)
        s1.sendall(b"Connection: close\r\n\r\n")
        got = b""
        try:
            while True:
                c = s1.recv(4096)
                if not c:
                    break
                got += c
        except OSError:
            pass
        s1.close()
        check("S4n a request whose headers arrive in two pieces 1.5 s apart is served normally (200)", b" 200 " in got, got[:30])
        data, dt = _raw(T.lan_port, b"GET /hello HTTP/1.1\r\nHost: x\r\nX-A: " + b"a" * 40000 + b"\r\n\r\n", 6)
        check("S4o 40 KB of headers are refused (no 200)", b" 200 " not in data, data[:30])
        check("S4p afterwards normal requests are unaffected (/hello, token /health, loopback /health)",
              http("GET", lurl(T, "/hello")).status_code == 200 and http("GET", lurl(T, "/health"), token=tok).status_code == 200
              and http("GET", T.base + "/health").status_code == 200)
        r = requests.get(lurl(T, "/health"), headers={"Authorization": "Bearer " + tok}, timeout=10)
        s2 = requests.Session()
        ok = all(s2.get(lurl(T, "/health"), headers={"Authorization": "Bearer " + tok}, timeout=10).status_code == 200 for _ in range(5))
        check("S4q keep-alive connections (5 requests on one session) are not cut by the header timer", r.status_code == 200 and ok)
    finally:
        T.stop()
        T.release_ports()


def scenario_logs(stubs_logs, codes_seen=()):
    print("\n== B-25 log hygiene")
    pat = re.compile(r"hp1_[A-Za-z0-9_-]{20,}")
    bad = []
    n = 0
    for path in stubs_logs:
        if not os.path.exists(path):
            continue
        n += 1
        txt = open(path, "r", encoding="utf-8", errors="replace").read()
        if pat.search(txt) or re.search(r"authorization", txt, re.I):
            bad.append(os.path.basename(path))
    server_logs = []
    ld = os.path.join(HERE, "logs")
    if os.path.isdir(ld):
        server_logs = [os.path.join(ld, f) for f in os.listdir(ld) if f.startswith("server") and f.endswith(".log")]
    for path in server_logs:
        txt = open(path, "r", encoding="utf-8", errors="replace").read()
        if pat.search(txt) or re.search(r"authorization", txt, re.I):
            bad.append(os.path.basename(path))
    check("B-25 no hp1_ token text and no auth-header text in %d stub log file(s) and %d server log file(s)" % (n, len(server_logs)), not bad and n > 0, bad)


# ----------------------------------------------------------------------------------------------
# Tailscale (lan.allow_tailscale): adapter picking, test hook, source filter with the local address, switch-off rule
# ----------------------------------------------------------------------------------------------
class _Env:
    """set / unset environment variables for a block and put them back afterwards"""

    def __init__(self, **kv):
        self.kv = kv
        self.saved = {}

    def __enter__(self):
        for k, v in self.kv.items():
            self.saved[k] = os.environ.get(k)
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
        return self

    def __exit__(self, *a):
        for k, v in self.saved.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v




def unit_tailscale():
    print("\n== Tailscale helpers (in-process)")
    pk = lan._pick_tailscale
    check("TS1a _pick_tailscale: adapter named Tailscale with 100.101.1.2 is taken", pk([("Tailscale", "Tailscale Tunnel", True, ["100.101.1.2"])]) == ["100.101.1.2"])
    check("TS1b ... also when only the description says Tailscale (renamed adapter '이더넷 3'), and in any letter case",
          pk([("이더넷 3", "Tailscale Tunnel", True, ["100.101.1.2"])]) == ["100.101.1.2"]
          and pk([("TAILSCALE", "wintun", True, ["100.64.0.1"])]) == ["100.64.0.1"])
    check("TS1c carrier CGNAT: adapter 'Ethernet' / 'Realtek' with 100.70.0.5 is NOT taken (next to a Tailscale adapter only the Tailscale address is the result)",
          pk([("Ethernet", "Realtek PCIe GbE", True, ["100.70.0.5"])]) == []
          and pk([("Ethernet", "Realtek PCIe GbE", True, ["100.70.0.5"]), ("Tailscale", "Tailscale Tunnel", True, ["100.101.1.2"])]) == ["100.101.1.2"])
    check("TS1d a Tailscale adapter that is down gives nothing", pk([("Tailscale", "Tailscale Tunnel", False, ["100.101.1.2"])]) == [])
    check("TS1e on a Tailscale adapter 192.168.x, 8.8.8.8, 100.128.0.1 / 100.63.255.255 (outside 100.64/10), IPv6 (also fd7a:115c:a1e0::) and junk are left out",
          pk([("Tailscale", "Tailscale Tunnel", True, ["192.168.1.5", "8.8.8.8", "100.128.0.1", "100.63.255.255", "fd7a:115c:a1e0::1", "2606:4700::1111", "junk", ""])]) == []
          and pk([("Tailscale", "Tailscale Tunnel", True, ["192.168.1.5", "8.8.8.8", "fd7a:115c:a1e0::1", "100.127.255.255"])]) == ["100.127.255.255"])
    check("TS1f at most 3 addresses, no duplicates; None names do not crash",
          pk([("Tailscale", "", True, ["100.64.0.1", "100.64.0.2", "100.64.0.2", "100.64.0.3", "100.64.0.4", "100.64.0.5"])]) == ["100.64.0.1", "100.64.0.2", "100.64.0.3"]
          and pk([(None, None, True, ["100.64.0.1"])]) == [])
    # ---- test hook
    with _Env(HOEHWA_TEST_HOOKS=None, HOEHWA_LAN_ASSUME_TAILSCALE="100.101.1.2"):
        lan._ts_cache = (float("-inf"), [])
        check("TS2a HOEHWA_LAN_ASSUME_TAILSCALE is ignored without HOEHWA_TEST_HOOKS=1", lan._fake_tailscale() is None and "100.101.1.2" not in lan.tailscale_addresses())
    lan._ts_cache = (float("-inf"), [])
    with _Env(HOEHWA_TEST_HOOKS="1", HOEHWA_LAN_ASSUME_TAILSCALE="100.101.1.2, 8.8.8.8,100.64.0.1,192.168.0.9,fd7a:115c:a1e0::1,junk,100.128.0.1,127.0.0.1,100.101.1.2"):
        check("TS2b with the hook only 100.64/10 IPv4 and loopback 127.x are taken (8.8.8.8, 192.168.x, IPv6, junk, 100.128.x out; duplicates once)",
              lan.tailscale_addresses() == ["100.101.1.2", "100.64.0.1", "127.0.0.1"], lan.tailscale_addresses())
    with _Env(HOEHWA_TEST_HOOKS="1", HOEHWA_LAN_ASSUME_TAILSCALE="100.64.0.1,100.64.0.2,100.64.0.3,100.64.0.4"):
        check("TS2c the hook list is capped at 3", len(lan.tailscale_addresses()) == 3)
    real_adapters = lan._windows_adapters
    calls = []
    try:
        lan._windows_adapters = lambda: (calls.append(1) or [("Tailscale", "Tailscale Tunnel", True, ["100.101.9.9"]), ("Ethernet", "Realtek", True, ["100.70.0.5"])])
        with _Env(HOEHWA_TEST_HOOKS="1", HOEHWA_LAN_ASSUME_TAILSCALE=""):
            check("TS2d an EMPTY hook value means 'no Tailscale' (the real adapters are not consulted)", lan._fake_tailscale() == [] and lan.tailscale_addresses() == [] and not calls, calls)
        with _Env(HOEHWA_TEST_HOOKS="1", HOEHWA_LAN_ASSUME_TAILSCALE=None):
            lan._ts_cache = (float("-inf"), [])
            a1, a2 = lan.tailscale_addresses(), lan.tailscale_addresses()
            check("TS2e without the hook value the adapter list decides (only the Tailscale adapter's 100.x), and the result is cached (second call does not read adapters)",
                  a1 == ["100.101.9.9"] and a2 == a1 and len(calls) == 1, (a1, len(calls)))
            lan._ts_cache = (time.monotonic() - 6.0, ["100.1.1.1"])
            check("TS2f the cache expires after 5 s", lan.tailscale_addresses() == ["100.101.9.9"] and len(calls) == 2)
            lan._ts_cache = (time.monotonic(), ["100.1.1.1"])
            check("TS2f2 fresh=True ignores a young cache (turning the link on and the watcher look again)", lan.tailscale_addresses(fresh=True) == ["100.101.9.9"] and len(calls) == 3)
        lan._windows_adapters = lambda: (_ for _ in ()).throw(OSError("boom"))
        with _Env(HOEHWA_TEST_HOOKS=None, HOEHWA_LAN_ASSUME_TAILSCALE=None):
            lan._ts_cache = (float("-inf"), [])
            check("TS2g an adapter-listing failure gives [] and no exception", lan.tailscale_addresses() == [])
    finally:
        lan._windows_adapters = real_adapters
        lan._ts_cache = (float("-inf"), [])
    # ---- config parsing
    check("TS5a _parse_update takes enabled / port / name only; the old keys (discovery, discovery_port, allow_cgnat, allow_tailscale) are ignored, bad values for the real keys are refused",
          lan._parse_update({"enabled": True, "port": 8863, "name": "A"}) == {"enabled": True, "port": 8863, "name": "A"}
          and lan._parse_update({"discovery": True, "discovery_port": "x", "allow_cgnat": 1, "allow_tailscale": "yes"}) == {}
          and all(lan._parse_update(b) is None for b in ({"enabled": "yes"}, {"enabled": 1}, {"port": 80}, {"port": True}, {"port": 70000}, {"name": 5}, {"name": "x" * 81})))
def _tcp_ok(port):
    return connect_code("127.0.0.1", port) == 0


class _Spy:
    """records every socket lan.py creates (type) and every bind (type, address) in this process; a bind on all interfaces is refused"""

    def __init__(self):
        self.created, self.binds = [], []

    def __enter__(self):
        import errno
        real = socket.socket
        self.real = real
        created, binds = self.created, self.binds

        class SpySocket(real):
            def __init__(self, family=-1, type=-1, proto=-1, fileno=None):
                super().__init__(family, type, proto, fileno)
                created.append(self.type)

            def bind(self, addr):
                binds.append((self.type, addr))
                if isinstance(addr, tuple) and addr and addr[0] in ("", "0.0.0.0", "::"):
                    raise OSError(errno.EACCES, "test spy: a bind on all interfaces is never done")
                return super().bind(addr)

        socket.socket = SpySocket
        return self

    def __exit__(self, *a):
        socket.socket = self.real

    def udp(self):
        return [t for t in self.created if t == socket.SOCK_DGRAM]

    def on_port(self, port):
        return [a for t, a in self.binds if isinstance(a, tuple) and len(a) >= 2 and a[1] == port]

    def wildcard(self):
        return [a for t, a in self.binds if isinstance(a, tuple) and a and a[0] in ("", "0.0.0.0", "::")]


def _state(cfg_lan, label, auto_start=True):
    """a fresh lan.S (own State) attached to a throw-away FastAPI app -> the config dict"""
    from fastapi import FastAPI
    lan.S = lan._State()
    cfg = {"lan": cfg_lan}
    lan.attach(FastAPI(), cfg, lambda c: None, logging.getLogger("inproc"), WORK, devices_file=os.path.join(WORK, "dev_inproc_%s.json" % label),
               persist=False, auto_start=auto_start)
    return cfg


def scenario_inproc_link():
    """lan.py driven in this process (own State, hook: Tailscale address = loopback, test ports 8862-8869): which sockets it opens and where it binds,
    several addresses, a missing / vanished address, the watcher, stale config keys. Nothing here binds 0.0.0.0 (the spy would refuse it)."""
    print("\n== link in-process: sockets, bind addresses, watcher, saved config")
    old_state = lan.S
    port = pick()
    H1 = dict(HOEHWA_TEST_HOOKS="1", HOEHWA_LAN_ASSUME_TAILSCALE="127.0.0.1", HOEHWA_LAN_WATCH_SECONDS=None)
    base_env = _Env(**H1)         # the hook stays set for the whole scenario: a running watcher thread must keep seeing the "Tailscale address"
    base_env.__enter__()
    try:
        # ---- A: one address, spy on sockets
        _state({"enabled": False, "port": port, "name": ""}, "a")
        with _Env(**H1), _Spy() as spy:
            res = lan._configure({"enabled": True})
            up = res == (None, None) and lan.S.listener is not None and lan.S.listener.alive()
        check("IP1 turning the link on with one Tailscale address (hook 127.0.0.1): ok, listener alive, bound to exactly that address",
              up and lan.S.bound == ["127.0.0.1"] and lan.S.listener.addrs == ["127.0.0.1"], (res, lan.S.bound))
        check("IP2 turning it on opens NO UDP socket (no discovery)", not spy.udp(), spy.udp())
        check("IP3 the listener's bind on the link port is exactly 127.0.0.1:port (the Tailscale address) and no bind on all interfaces was attempted",
              spy.on_port(port) == [("127.0.0.1", port)] and not spy.wildcard(), (spy.on_port(port), spy.wildcard()))
        check("IP3b the port accepts on that address", _tcp_ok(port))
        ls = lan.S.listener
        with _Env(**H1):
            gone_now = lan._watch_once(ls)
        check("IP4 watcher check while the address is still there: nothing happens", gone_now is False and lan.S.listener is ls and ls.alive())
        with _Env(HOEHWA_TEST_HOOKS="1", HOEHWA_LAN_ASSUME_TAILSCALE="", HOEHWA_LAN_WATCH_SECONDS=None):
            closed = lan._watch_once(ls)
        ok_closed, _ = wait_closed("127.0.0.1", port, 3.0)
        check("IP5 the Tailscale address vanished: the watcher closes the listener, enabled false (not saved), the reason is in S.error, port closed, code gone",
              closed is True and lan.S.listener is None and lan.S.lan["enabled"] is False and lan.S.error == lan.MSG["tailscale_lost"] and ok_closed
              and lan.S.bound == [] and lan._pairing_view()["code"] is None, (closed, lan.S.error[:20]))
        st = lan._status()
        check("IP5b _status shows it: enabled false, listening false, bind [], error = that reason", st["enabled"] is False and st["listening"] is False and st["bind"] == []
              and st["error"] == lan.MSG["tailscale_lost"])
        with _Env(**H1):
            res = lan._configure({"enabled": True})
        check("IP6 the next turn-on looks the address up again and works", res == (None, None) and lan.S.listener is not None and _tcp_ok(port) and lan.S.error == "", res)
        with _Env(**H1):
            lan._configure({"enabled": False})
        check("IP6b turning it off closes the port again", wait_closed("127.0.0.1", port, 3.0)[0] and lan.S.listener is None)
        # ---- watcher thread
        with _Env(HOEHWA_TEST_HOOKS="1", HOEHWA_LAN_ASSUME_TAILSCALE="127.0.0.1", HOEHWA_LAN_WATCH_SECONDS="0.5"):
            res = lan._configure({"enabled": True})
            os.environ["HOEHWA_LAN_ASSUME_TAILSCALE"] = ""
            t0 = time.time()
            while time.time() - t0 < 4.0 and lan.S.listener is not None:
                time.sleep(0.1)
        check("IP7 the watcher THREAD notices the vanished address on its own (interval 0.5 s) and closes the link",
              res == (None, None) and lan.S.listener is None and lan.S.error == lan.MSG["tailscale_lost"] and wait_closed("127.0.0.1", port, 3.0)[0], "%.1fs" % (time.time() - t0))
        # ---- B: two addresses
        with _Env(HOEHWA_TEST_HOOKS="1", HOEHWA_LAN_ASSUME_TAILSCALE="127.0.0.1,127.0.0.2", HOEHWA_LAN_WATCH_SECONDS=None), _Spy() as spy:
            res = lan._configure({"enabled": True})
        check("IP8 two Tailscale addresses: both are bound (one socket each), nothing else, no wildcard, no UDP",
              res == (None, None) and sorted(lan.S.bound) == ["127.0.0.1", "127.0.0.2"] and sorted(spy.on_port(port)) == [("127.0.0.1", port), ("127.0.0.2", port)]
              and not spy.wildcard() and not spy.udp(), (res, spy.on_port(port)))
        check("IP8b both accept", connect_code("127.0.0.1", port) == 0 and connect_code("127.0.0.2", port) == 0)
        with _Env(HOEHWA_TEST_HOOKS="1", HOEHWA_LAN_ASSUME_TAILSCALE="127.0.0.2", HOEHWA_LAN_WATCH_SECONDS=None):
            kept = lan._watch_once(lan.S.listener)
        check("IP8c one of two addresses vanishing does not close the link (the other one still exists)", kept is False and lan.S.listener is not None and connect_code("127.0.0.2", port) == 0)
        with _Env(**H1):
            lan._configure({"enabled": False})
        # ---- C: no address / address not on this PC / port busy
        with _Env(HOEHWA_TEST_HOOKS="1", HOEHWA_LAN_ASSUME_TAILSCALE="", HOEHWA_LAN_WATCH_SECONDS=None):
            res = lan._configure({"enabled": True})
        check("IP9 no Tailscale address: (409, no_tailscale), nothing listens, enabled stays false", res == (409, "no_tailscale") and lan.S.listener is None
              and lan.S.lan["enabled"] is False and not _tcp_ok(port), res)
        with _Env(HOEHWA_TEST_HOOKS="1", HOEHWA_LAN_ASSUME_TAILSCALE="100.101.102.103", HOEHWA_LAN_WATCH_SECONDS=None):
            res = lan._configure({"enabled": True})
        check("IP10 an address that is not on this PC (bind: address not available): (409, no_tailscale), nothing listens", res == (409, "no_tailscale") and lan.S.listener is None
              and not _tcp_ok(port), res)
        blocker = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        blocker.bind(("127.0.0.1", port))
        blocker.listen(1)
        try:
            with _Env(**H1):
                res = lan._configure({"enabled": True})
        finally:
            blocker.close()
        check("IP11 port taken by another program: (409, lan_port_busy)", res == (409, "lan_port_busy") and lan.S.listener is None, res)
        # ---- D: saved config at start (start_if_enabled) incl. stale keys of the old versions
        stale = {"enabled": True, "port": port, "name": "", "discovery": True, "discovery_port": 8776, "allow_cgnat": True, "allow_tailscale": True}
        with _Env(**H1):
            cfg = _state(dict(stale), "d1")
            keys_ok = set(cfg["lan"]) == {"enabled", "port", "name"}
            lan.start_if_enabled()
            up = lan.S.listener is not None and lan.S.listener.alive() and _tcp_ok(port)
            err1 = lan.S.error
            lan.shutdown()
        check("IP12 saved enabled=true with stale discovery / allow_* keys: the keys are dropped (no error), start_if_enabled brings the link up on the Tailscale address",
              keys_ok and up and err1 == "", (sorted(cfg["lan"]), up, err1))
        check("IP12b shutdown closes the port", wait_closed("127.0.0.1", port, 3.0)[0])
        with _Env(HOEHWA_TEST_HOOKS="1", HOEHWA_LAN_ASSUME_TAILSCALE="", HOEHWA_LAN_WATCH_SECONDS=None):
            cfg = _state(dict(stale), "d2")
            lan.start_if_enabled()
            err2, en2, up2 = lan.S.error, cfg["lan"]["enabled"], lan.S.listener is not None
        check("IP13 saved enabled=true but no Tailscale address at start: stays off (not saved), error = the Korean no_tailscale text, nothing listens",
              not up2 and en2 is False and err2 == NO_TAILSCALE_TEXT and not _tcp_ok(port), (up2, en2, err2[:20]))
        cfg = _state({"enabled": False, "port": 80, "name": "  x  \n", "discovery": "weird"}, "d3", auto_start=False)
        check("IP14 attach() repairs a bad port (-> 8775 default value, never opened here) and cleans the name; unknown keys vanish",
              cfg["lan"] == {"enabled": False, "port": 8775, "name": "x"}, cfg["lan"])
        cfg = _state({"enabled": True, "port": port, "name": ""}, "d4", auto_start=False)
        check("IP15 a test server (auto_start False) never starts from a saved enabled=true", cfg["lan"]["enabled"] is False)
    finally:
        try:
            with _Env(**H1):
                lan.shutdown()
        except Exception:
            pass
        lan.S = old_state
        base_env.__exit__()
        release(port)
def main():
    try:
        unit_checks()
        unit_security()
        unit_tailscale()
        scenario_inproc_link()
        only_unit = _arg("--only") == "unit"
        ip2 = None if only_unit else own_ip()
        if only_unit:
            pass
        elif EXTERNAL:
            lp = _arg("--lan-port")
            if not lp:
                sys.exit("--base mode needs --lan-port (a free port for the link of that server)")
            T = Ext(EXTERNAL, int(lp))
            set_lan(T, enabled=False)       # start from "off, nobody paired" (this is a test server: it is yours to reset)
            http("POST", T.base + "/lan/devices/revoke", json={"all": True})
            core(T, ip2)
            for n in ("B-10b expiry", "B-16 restart persistence", "rate limit"):
                skip(n, "needs to start/kill a server: only in self-hosted mode")
        else:
            T = scenario_core_stub(ip2)
            scenario_ttl()
            scenario_netsafe()
            scenario_slow()
            scenario_hdr()
            scenario_acl()
            scenario_restart()
            scenario_rate()
            scenario_logs(sorted(os.path.join(WORK, f) for f in os.listdir(WORK) if f.startswith("stub_")))
    finally:
        for s_ in list(Stub.live):
            s_.stop()
    n = len(results)
    k = sum(1 for _, ok in results if ok)
    still = [s_ for s_ in Stub.live]
    print()
    if k == n and not skips and not still and n >= (15 if _arg("--only") == "unit" else 27):
        print("LAN_TEST_RESULT PASS %d/%d%s" % (k, n, (" (notes: %s)" % "; ".join(notes)) if notes else ""))
        code = 0
    else:
        print("LAN_TEST_RESULT %s %d/%d (skips: %s)" % ("FAIL" if k != n else "PARTIAL", k, n, skips))
        for name, ok in results:
            if not ok:
                print("  FAILED:", name)
        code = 1
    if "--keep" not in sys.argv and not _arg("--work-dir"):
        shutil.rmtree(WORK, ignore_errors=True)
    sys.exit(code)


if __name__ == "__main__":
    main()
