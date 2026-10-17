# -*- coding: utf-8 -*-
"""Tests of the phone link (lan.py): pairing, tokens, allow-list, ports, UDP discovery. No model is needed.

  .venv\\Scripts\\python.exe test_lan.py [--work-dir DIR] [--keep]
      Starts its OWN stub servers (lan_stub_server.py) on free ports in 8830-8839 (HTTP), 8840-8849 (LAN) and 18776-18790 (UDP),
      runs every scenario, kills only the processes it started. It never touches the app's real ports.
  .venv\\Scripts\\python.exe test_lan.py --base http://127.0.0.1:8830 --lan-port 8840 --udp-port 18776 [--devices-file F] [--pid N]
      Runs the core scenarios against a server YOU started (stub or server.py --port ... --tag ...); --base is required in this
      mode and the app's own server is refused. Scenarios that need to start/kill processes are reported as SKIP.

Last line:  LAN_TEST_RESULT PASS n/n   (exit 0)   |   LAN_TEST_RESULT FAIL k/n | PARTIAL ...  (exit 1)
Tokens are only ever printed as their first 4 characters; codes are never printed.
"""
import base64
import hashlib
import hmac
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import time
from collections import deque

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


def udp_free(port):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.bind(("127.0.0.1", port))
        return True
    except OSError:
        return False
    finally:
        s.close()


_USED = set()


def pick(lo, hi, udp=False):
    for p in range(lo, hi + 1):
        if p in _USED:
            continue
        if (udp_free(p) if udp else tcp_free(p)):
            _USED.add(p)
            return p
    sys.exit("no free port in %d-%d" % (lo, hi))


def release(p):
    _USED.discard(p)


def own_ip():
    """a non-loopback IPv4 of this PC: a private one if there is any (-> (ip, True)), else the default-route one (-> (ip, False))"""
    pr = lan.private_addresses()
    if pr:
        return pr[0], True
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("10.255.255.255", 1))
        ip = s.getsockname()[0]
        return (ip, False) if not ip.startswith("127.") else (None, False)
    except OSError:
        return None, False
    finally:
        s.close()


def listening_pids(port):
    out = subprocess.run(["netstat", "-ano", "-p", "TCP"], capture_output=True, text=True, errors="replace").stdout
    pids = []
    for line in out.splitlines():
        p = line.split()
        if len(p) >= 5 and p[0] == "TCP" and p[3] == "LISTENING" and p[1].rsplit(":", 1)[-1] == str(port):
            pids.append(int(p[4]))
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


def udp_ask(port, payload, wait=1.5, repeat=3, host="127.0.0.1"):
    """-> parsed JSON reply | None (no reply). Windows reports an ICMP 'port closed' as a reset: that is also 'no reply'."""
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(wait)
    try:
        for _ in range(repeat):
            try:
                s.sendto(payload, (host, port))
            except OSError:
                pass
            time.sleep(0.05)
        end = time.time() + wait
        while time.time() < end:
            s.settimeout(max(0.05, end - time.time()))
            try:
                data, _ = s.recvfrom(4096)
                try:
                    return json.loads(data.decode("utf-8"))
                except Exception:
                    return {"_raw": data}
            except socket.timeout:
                return None
            except ConnectionResetError:
                continue
            except OSError:
                return None
        return None
    finally:
        s.close()


DISCOVER = json.dumps({"hoehwa": 1, "op": "discover"}).encode()


# ----------------------------------------------------------------------------------------------
# stub process
# ----------------------------------------------------------------------------------------------
class Stub:
    live = []

    def __init__(self, name, lan_bind="127.0.0.1", env=None, enabled=False, devfile=None):
        self.name = name
        self.lan_bind = lan_bind
        self.env = env or {}
        self.enabled = enabled
        self.devfile = devfile or os.path.join(WORK, "dev_%s.json" % name)
        self.out_path = os.path.join(WORK, "stub_%s.out" % name)
        self.err_path = os.path.join(WORK, "stub_%s.err" % name)
        self.proc = None
        self.pid = None
        self.http_port = self.lan_port = self.udp_port = None

    @property
    def base(self):
        return "http://127.0.0.1:%d" % self.http_port

    def lan_url(self, host="127.0.0.1"):
        return "http://%s:%d" % (host, self.lan_port)

    def start(self, keep_ports=False):
        if not keep_ports or self.http_port is None:
            self.http_port = pick(8830, 8839)
            self.lan_port = pick(8840, 8849)
            self.udp_port = pick(18776, 18790, udp=True)
        env = dict(os.environ)
        for k in ("HOEHWA_TEST_HOOKS", "HOEHWA_LAN_CODE_TTL", "HOEHWA_LAN_ASSUME_PRIVATE", "HOEHWA_LAN_PREAUTH_TIMEOUT", "HOEHWA_LAN_BODY_TIMEOUT"):
            env.pop(k, None)
        base_env = {"HOEHWA_TEST_HOOKS": "1", "HOEHWA_LAN_ASSUME_PRIVATE": "1"}   # this PC may have no private address: pretend it has one
        base_env.update(self.env)
        env.update({k: v for k, v in base_env.items() if v is not None})
        cmd = [sys.executable, STUB, "--port", str(self.http_port), "--lan-port", str(self.lan_port), "--lan-discovery-port",
               str(self.udp_port), "--lan-bind", self.lan_bind, "--devices-file", self.devfile, "--tag", self.name]
        if self.enabled:
            cmd.append("--lan-enabled")
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
        for p in (self.http_port, self.lan_port, self.udp_port):
            release(p)


# ----------------------------------------------------------------------------------------------
# API shorthands against a "target" T (.base .lan_port .udp_port .devfile .pid)
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

    def __init__(self, base, lan_port, udp_port):
        self.base, self.lan_port, self.udp_port = base, lan_port, udp_port
        self.devfile = _arg("--devices-file")
        self.pid = int(_arg("--pid")) if _arg("--pid") else None
        self.http_port = int(base.rsplit(":", 1)[-1])


# ----------------------------------------------------------------------------------------------
# scenarios
# ----------------------------------------------------------------------------------------------
def unit_checks():
    print("\n== helpers (in-process, nothing started)")
    cases = {"192.168.0.12": True, "10.1.2.3": True, "172.16.5.5": True, "172.31.255.1": True, "172.32.0.1": False, "169.254.1.1": False,
             "127.0.0.1": False, "8.8.8.8": False, "175.212.223.8": False, "100.64.0.1": False, "abc": False}
    bad = {k: lan._is_private_lan(k) for k, v in cases.items() if lan._is_private_lan(k) != v}
    check("U-01 private-address filter (10/8, 172.16/12, 192.168/16 only)", not bad, bad or "")
    pr = lan.private_addresses()
    check("U-02 private_addresses() returns only private IPv4, at most 3", len(pr) <= 3 and all(lan._is_private_lan(a) for a in pr), pr)
    check("U-03 loopback test: 127.0.0.1 / ::1 / ::ffff:127.0.0.1 yes, 192.168.0.1 / empty no",
          lan._is_loopback("127.0.0.1") and lan._is_loopback("::1") and lan._is_loopback("::ffff:127.0.0.1")
          and not lan._is_loopback("192.168.0.1") and not lan._is_loopback(""))
    check("U-04 allow-list has exactly the 16 documented routes and none of /mic /llm /lan(admin) /docs",
          len(lan.ALLOW) == 16 and not any(p.startswith(("/mic", "/llm", "/docs", "/debug")) for _, p in lan.ALLOW)
          and ("GET", "/lan") not in lan.ALLOW and ("POST", "/lan/code") not in lan.ALLOW)


def core(T, ip2, ip2_private):
    """B-03 .. B-23 on target T (LAN off at the start). ip2 = a non-loopback IPv4 of this PC"""
    L, U = T.lan_port, T.udp_port
    stub = bool(jb(http("GET", T.base + "/health")).get("stub"))     # only the stub gives canned 200s; a real server may lack models
    if get_lan(T).get("bind") == "127.0.0.1":
        ip2 = None      # the link of this server listens on loopback only: the non-loopback address cannot reach it
        note("non-loopback address checks not run", "this server was started with --lan-bind 127.0.0.1")
    print("\n== core scenarios (%s)" % (("stub " + T.name) if hasattr(T, "name") else ("external server, stub=%s" % stub)))
    # ---- B-03 default: off
    st = get_lan(T)
    check("B-03a default: GET /lan -> enabled false, listening false", st.get("enabled") is False and st.get("listening") is False, st.get("error", ""))
    check("B-03b default: LAN port refuses 127.0.0.1", connect_code("127.0.0.1", L) != 0)
    if ip2:
        check("B-03c default: LAN port refuses this PC's non-loopback address (%s)" % ("private" if ip2_private else "public, no private IPv4 on this PC"),
              connect_code(ip2, L) != 0)
    else:
        pass
    check("B-07a loopback GET /health without token, LAN off -> 200", http("GET", T.base + "/health").status_code == 200)
    hl = jb(http("GET", T.base + "/hello"))
    check("hello (loopback, off): keys hoehwa,name,pairing_open and pairing_open false",
          set(hl) == {"hoehwa", "name", "pairing_open"} and hl.get("hoehwa") == 1 and hl.get("pairing_open") is False, hl)
    check("udp discovery port closed while off: no reply", udp_ask(U, DISCOVER, wait=1.0, repeat=2) is None)
    r = http("POST", T.base + "/lan/code", json={})
    check("lan_off: POST /lan/code while off -> 409 lan_off", r.status_code == 409 and jb(r).get("code") == "lan_off", r.status_code)

    # ---- bad inputs to POST /lan
    for body, label in (({"port": 80}, "port 80"), ({"enabled": "yes"}, "enabled as string"), ({"port": True}, "port true"),
                        ({"discovery_port": 70000}, "udp port 70000"), ({"name": 5}, "name number")):
        r = http("POST", T.base + "/lan", json=body)
        check("POST /lan rejects %s -> 400" % label, r.status_code == 400, r.status_code)
    r = http("POST", T.base + "/lan", data=b"{broken", headers={"Content-Type": "application/json"})
    check("POST /lan with broken JSON -> 400", r.status_code == 400, r.status_code)
    check("rejected updates changed nothing (still off)", get_lan(T).get("enabled") is False)

    # ---- B-04 turn on
    t0 = time.time()
    r = set_lan(T, enabled=True, port=L, discovery_port=U)
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
    check("B-04d discovery listening true", st.get("discovery_listening") is True)
    check("B-07b loopback GET /health without token, LAN on -> 200", http("GET", T.base + "/health").status_code == 200)
    check("hello over the LAN listener needs no token and reveals only name + pairing_open",
          set(jb(http("GET", lurl(T, "/hello")))) == {"hoehwa", "name", "pairing_open"} and jb(http("GET", lurl(T, "/hello"))).get("pairing_open") is True)

    # ---- B-05 / B-06 token checks
    r = http("GET", lurl(T, "/health"))
    check("B-05 LAN /health without token -> 401 token_missing", r.status_code == 401 and jb(r).get("code") == "token_missing", r.status_code)
    if ip2:
        r = http("GET", lurl(T, "/health", ip2))
        check("B-05b same through the non-loopback address -> 401", r.status_code == 401 and jb(r).get("code") == "token_missing", r.status_code)
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
    hosts = [("127.0.0.1", "loopback")] + ([(ip2, "non-loopback %s" % ("private" if ip2_private else "public"))] if ip2 else [])
    for host, label in hosts:
        h = http("GET", lurl(T, "/health", host), token=tok1)
        s = http("POST", lurl(T, "/stt", host), token=tok1, json={"lang": "en", "audio_b64": "AAAA"})
        m = http("GET", lurl(T, "/lan/me", host), token=tok1)
        stt_ok = (s.status_code == 200 and "text" in jb(s)) if stub else s.status_code not in (401, 403, 413, 429)    # real server: models may be missing
        check("B-11 valid token via %s: /health 200 ok, /stt %s, /lan/me 200 own id" % (label, "200 text" if stub else "reaches the app"),
              h.status_code == 200 and jb(h).get("ok") is True and stt_ok
              and m.status_code == 200 and jb(m).get("device_id") == dev1, (h.status_code, s.status_code, m.status_code))
    if not ip2:
        note("B-11 / B-03c / B-05b non-loopback (private-IP) variants NOT verified",
             "the tests never bind 0.0.0.0; this PC has %s private IPv4 address" % ("a" if ip2_private else "no"))
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

    # ---- B-18 discovery on
    rep = udp_ask(U, DISCOVER, wait=1.0)
    check("B-18 UDP discover -> reply within 1 s with exactly keys hoehwa,op,name,port; port == LAN port",
          isinstance(rep, dict) and set(rep) == {"hoehwa", "op", "name", "port"} and rep.get("hoehwa") == 1 and rep.get("op") == "here" and rep.get("port") == L
          and rep.get("name") == jb(http("GET", T.base + "/hello")).get("name"), rep)
    # burst limit
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(0.3)
    for _ in range(40):
        s.sendto(DISCOVER, ("127.0.0.1", U))
    n = 0
    end = time.time() + 1.0
    while time.time() < end:
        try:
            s.recvfrom(1024)
            n += 1
        except (socket.timeout, OSError):
            if time.time() > end:
                break
    s.close()
    check("discovery answers at most 10 packets per second (40 sent in a burst, %d answered)" % n, 1 <= n <= 10)
    time.sleep(1.1)

    # ---- B-19 no answer
    junk = [b"\xff\xfe\x00garbage", b'{"op":"discover"}', b'{"hoehwa":1,"op":"discover","x":1}', b'{"hoehwa":true,"op":"discover"}', b'{"hoehwa":1,"op":"hello"}',
            b"[1,2,3]", b"", b"x" * 2048, json.dumps({"hoehwa": 1, "op": "discover", "pad": "p" * 200}).encode()]
    bad = [i for i, p in enumerate(junk) if udp_ask(U, p, wait=0.6, repeat=3) is not None]
    check("B-19a LAN on + discovery on: broken bytes / wrong keys / bool / extra key / 2 KB packet / oversize -> no reply", not bad, bad)
    set_lan(T, discovery=False)
    st = get_lan(T)
    check("B-19b discovery off + LAN on: discovery_listening false", st.get("discovery_listening") is False and st.get("listening") is True)
    check("B-19c discovery off + LAN on: valid discover x3 -> no reply for 1.5 s", udp_ask(U, DISCOVER, wait=1.5) is None)
    check("B-19d discovery off: another program can bind the UDP port", udp_free(U))
    set_lan(T, discovery=True)
    check("discovery on again -> replies again", isinstance(udp_ask(U, DISCOVER, wait=1.0), dict))

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
    check("B-17b off: listening false, discovery_listening false, code hidden, devices kept", st.get("listening") is False and st.get("discovery_listening") is False
          and (st.get("pairing") or {}).get("code") is None and len(st.get("devices", [])) >= 1)
    check("B-17c UDP port is free for another program after turning off", udp_free(U))
    check("B-17d discover while off -> no reply", udp_ask(U, DISCOVER, wait=1.0, repeat=2) is None)
    if ip2:
        check("B-17e non-loopback address refuses too", connect_code(ip2, L) != 0)
    check("B-07c loopback /health without token while LAN is off again -> 200", http("GET", T.base + "/health").status_code == 200)
    r = set_lan(T, enabled=True)
    check("B-17f turning it on again -> 200 listening", r.status_code == 200 and jb(r).get("listening") is True)
    check("B-17g an old token works again after off/on", http("GET", lurl(T, "/health"), token=keep_tok).status_code == 200)
    check("a new code was made for the new session", bool((get_lan(T).get("pairing") or {}).get("code")))

    # ---- B-23 port busy
    set_lan(T, enabled=False)
    busy_port = pick(8840, 8849)
    blocker = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    blocker.bind((get_lan(T).get("bind") or "0.0.0.0", busy_port))    # same address family as the link, so the OS really sees a conflict
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
    newp = pick(8840, 8849)
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
        r = set_lan(T, enabled=True, port=T.lan_port, discovery_port=T.udp_port)
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
        set_lan(T, enabled=True, port=T.lan_port, discovery_port=T.udp_port)
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
        set_lan(T, enabled=True, port=T.lan_port, discovery_port=T.udp_port)
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
    finally:
        T.stop()
        T.release_ports()


def scenario_core_stub(ip2, ip2_private):
    T = Stub("core").start()      # 127.0.0.1 only: tests never bind 0.0.0.0
    try:
        core(T, ip2, ip2_private)
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


def gate_call(ip, method="GET", path="/hello", headers=None):
    """run LanGate in-process with a made-up scope['client'] -> (app_called, messages sent to the client)"""
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
    asyncio.run(lan.LanGate(app)(scope, receive, send))
    return bool(called), sent


def unit_security():
    print("\n== security helpers (in-process)")
    allowed = ["127.0.0.1", "127.5.5.5", "10.1.2.3", "172.16.0.1", "172.31.255.255", "192.168.1.1", "169.254.9.9", "::1", "fe80::1",
               "fd12:3456::1", "fc00::1", "::ffff:192.168.0.2"]
    denied = ["8.8.8.8", "175.212.223.8", "172.32.0.1", "172.15.255.255", "192.169.0.1", "11.0.0.1", "100.64.0.1", "100.127.255.255", "0.0.0.0",
              "2001:db8::1", "2606:4700::1111", "::ffff:8.8.8.8", "fec0::1", "ff02::1", "junk", ""]
    saved = lan.S.lan.get("allow_cgnat")
    try:
        lan.S.lan["allow_cgnat"] = False
        bad_a = [x for x in allowed if not lan._source_allowed(x)]
        bad_d = [x for x in denied if lan._source_allowed(x)]
        check("S1a source filter: loopback / 10/8 / 172.16/12 / 192.168/16 / 169.254/16 / ::1 / fe80::/10 / fc00::/7 / mapped-private allowed", not bad_a, bad_a)
        check("S1b source filter: public IPv4/IPv6, CGNAT (default), 172.32, mapped-public, multicast, junk and empty denied", not bad_d, bad_d)
        lan.S.lan["allow_cgnat"] = True
        check("S1c lan.allow_cgnat=true admits only 100.64.0.0/10", lan._source_allowed("100.64.0.1") and lan._source_allowed("100.127.255.255")
              and not lan._source_allowed("100.128.0.1") and not lan._source_allowed("100.63.255.255") and not lan._source_allowed("8.8.8.8"))
        lan.S.lan["allow_cgnat"] = False
        res = {ip: gate_call(ip) for ip in ("8.8.8.8", "175.212.223.8", "100.64.0.1", "2606:4700::1111", "192.168.0.7", "127.0.0.1", "169.254.1.1", "fd00::1", "fe80::2")}
        silent = all(not res[ip][0] and res[ip][1] == [] for ip in ("8.8.8.8", "175.212.223.8", "100.64.0.1", "2606:4700::1111"))
        served = all(res[ip][0] for ip in ("192.168.0.7", "127.0.0.1", "169.254.1.1", "fd00::1", "fe80::2"))
        check("S1d LanGate with a fake scope['client']: public / CGNAT sources get NO answer and never reach the app; private / loopback / link-local / ULA do",
              silent and served, {ip: (v[0], len(v[1])) for ip, v in res.items()})
        called, sent = gate_call("8.8.8.8", "POST", "/pair")
        called2, sent2 = gate_call("8.8.8.8", "GET", "/health")
        check("S1e a public source cannot reach /pair or any other path (no answer, no lock side effect)", not called and not sent and not called2 and not sent2
              and lan.S.fails == 0 and lan.S.locked is False)
        called, sent = gate_call("192.168.0.7", "GET", "/health")
        check("S1f a private source without a token still gets 401 (the filter is in front of the rest, not instead of it)",
              not called and sent and sent[0]["status"] == 401)
        lan.S.lan["allow_cgnat"] = True
        called, sent = gate_call("100.64.0.9")
        lan.S.lan["allow_cgnat"] = False
        check("S1g with allow_cgnat a CGNAT source is served", called)
    finally:
        lan.S.lan["allow_cgnat"] = saved
    P = lan._make_protocol()
    p = P.__new__(P)
    t = FakeTransport("8.8.8.8")
    try:
        p.connection_made(t)
    except AttributeError:
        pass          # it went on to the normal setup instead of dropping the connection: the check below fails
    check("S1h the listener's protocol aborts a connection from a public address before reading anything", t.aborted and p.transport is t)
    p2 = P.__new__(P)
    t2 = FakeTransport("192.168.0.9")
    try:
        p2.connection_made(t2)
    except AttributeError:
        pass          # the real init state is not built here; what matters is that it was not aborted
    check("S1i ... and does not abort a private address", not t2.aborted)
    check("S4c regexes use \\Z: a code / nonce / token with a trailing newline does not match",
          not lan.CODE_RE.match("123456\n") and lan.CODE_RE.match("123456") and not lan.NONCE_RE.match("a1b2c3d4\n")
          and not lan.TOKEN_RE.match("Bearer hp1_" + "A" * 43 + "\n") and not lan.ID_RE.match("a1b2c3d4\n") and not lan.HASH_RE.match("a" * 64 + "\n"))
    saved_env = {k: os.environ.get(k) for k in ("HOEHWA_TEST_HOOKS", "HOEHWA_LAN_CODE_TTL", "HOEHWA_LAN_ASSUME_PRIVATE")}
    try:
        os.environ.pop("HOEHWA_TEST_HOOKS", None)
        os.environ["HOEHWA_LAN_CODE_TTL"] = "2"
        os.environ["HOEHWA_LAN_ASSUME_PRIVATE"] = "0"
        a = (lan._code_ttl(), lan._forced_private())
        os.environ["HOEHWA_TEST_HOOKS"] = "1"
        b = (lan._code_ttl(), lan._forced_private())
        check("HOEHWA_LAN_CODE_TTL / HOEHWA_LAN_ASSUME_PRIVATE are ignored without HOEHWA_TEST_HOOKS=1 and read with it",
              a == (300.0, None) and b == (2.0, False), (a, b))
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


class FakeSock:
    def __init__(self):
        self.sent = []

    def sendto(self, data, addr):
        self.sent.append((data, addr))


def disc_reply(ip, payload=None):
    """feed one UDP packet from a made-up source address to the discovery handler -> replies it would send"""
    d = lan._Discovery.__new__(lan._Discovery)
    d.sock = FakeSock()
    d.sent = deque()
    d._handle(payload if payload is not None else DISCOVER, (ip, 4444))
    return d.sock.sent


def unit_discovery():
    print("\n== UDP discovery source filter (in-process)")
    saved = lan.S.lan.get("allow_cgnat")
    try:
        lan.S.lan["allow_cgnat"] = False
        denied = {ip: disc_reply(ip) for ip in ("8.8.8.8", "175.212.223.8", "100.64.0.1", "2606:4700::1111", "::ffff:8.8.8.8", "junk")}
        allowed = {ip: disc_reply(ip) for ip in ("127.0.0.1", "192.168.0.7", "10.2.3.4", "172.16.9.9", "169.254.3.3", "fd00::1", "fe80::5")}
        check("S1k discovery: a valid discover packet from a public / CGNAT / junk source gets NO reply", all(v == [] for v in denied.values()),
              {k: len(v) for k, v in denied.items()})
        ok = all(len(v) == 1 for v in allowed.values())
        body = json.loads(allowed["192.168.0.7"][0][0].decode()) if ok else {}
        check("S1l discovery: the same packet from loopback / private / link-local / ULA sources is answered (keys hoehwa,op,name,port; sent back to the asker)",
              ok and set(body) == {"hoehwa", "op", "name", "port"} and allowed["192.168.0.7"][0][1] == ("192.168.0.7", 4444), {k: len(v) for k, v in allowed.items()})
        lan.S.lan["allow_cgnat"] = True
        check("S1m discovery: with lan.allow_cgnat a CGNAT source is answered, a public one still is not",
              len(disc_reply("100.64.0.1")) == 1 and disc_reply("8.8.8.8") == [])
        lan.S.lan["allow_cgnat"] = False
        check("S1n discovery: a bad packet from an allowed source is still ignored (wrong keys, bool, 2 KB)",
              disc_reply("192.168.0.7", b'{"hoehwa":true,"op":"discover"}') == [] and disc_reply("192.168.0.7", b"x" * 2048) == []
              and disc_reply("192.168.0.7", b'{"hoehwa":1,"op":"discover","x":1}') == [])
    finally:
        lan.S.lan["allow_cgnat"] = saved


def csrf_checks(T):
    """S2: management endpoints refuse a web page's request (Origin / Host / Content-Type); the PC app's own style still works"""
    port = T.http_port
    url = T.base + "/lan"
    new_code(T)            # an active code, so "cancel" and the lock state are observable
    cur = get_lan(T)
    same = json.dumps({"discovery": cur.get("discovery")})       # a body that changes nothing if it were accepted
    flip = json.dumps({"discovery": not cur.get("discovery")})
    evil_all = requests.post(url, data=flip, headers={"Content-Type": "text/plain", "Origin": "http://evil.example", "Host": "evil.example:%d" % port}, timeout=15)
    check("S2a POST /lan with Content-Type text/plain + Origin evil + Host evil + body {discovery:flipped} -> 403 bad_origin",
          evil_all.status_code == 403 and jb(evil_all).get("code") == "bad_origin", (evil_all.status_code, jb(evil_all).get("code")))
    check("S2b ... and the setting did not change", get_lan(T).get("discovery") == cur.get("discovery"))
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
    # lan.allow_cgnat is a plain config flag through POST /lan
    r = set_lan(T, allow_cgnat=True)
    on = jb(r).get("allow_cgnat")
    r2 = set_lan(T, allow_cgnat="yes")
    r3 = set_lan(T, allow_cgnat=False)
    check("S1j POST /lan {allow_cgnat:true} shows in GET /lan; a string value is 400; false switches it off again",
          r.status_code == 200 and on is True and r2.status_code == 400 and jb(r3).get("allow_cgnat") is False)


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


def scenario_netsafe():
    print("\n== S3 turning the link on needs a private network address")
    expect_msg = "이 PC는 공유기 없이 인터넷에 직접 연결돼 있어요. 휴대폰 연결을 켜면 인터넷에서 접근될 수 있어요. 공유기에 연결하거나 휴대폰 핫스팟을 쓰세요."
    T = Stub("net0", env={"HOEHWA_LAN_ASSUME_PRIVATE": "0"}).start()
    try:
        st = get_lan(T)
        check("S3a no private address: GET /lan says network_safe false with a Korean reason, addresses []",
              st.get("network_safe") is False and "공유기" in st.get("network_reason", "") and st.get("addresses") == [], st.get("network_reason", "")[:30])
        r = set_lan(T, enabled=True, port=T.lan_port, discovery_port=T.udp_port)
        check("S3b POST /lan {enabled:true} -> 409 no_private_network with the agreed Korean message",
              r.status_code == 409 and jb(r).get("code") == "no_private_network" and jb(r).get("error") == expect_msg, (r.status_code, jb(r).get("code")))
        st = get_lan(T)
        check("S3c nothing was started: enabled false, listening false, LAN port and UDP port closed, no code",
              st.get("enabled") is False and st.get("listening") is False and connect_code("127.0.0.1", T.lan_port) != 0 and udp_free(T.udp_port)
              and (st.get("pairing") or {}).get("code") is None)
        r = set_lan(T, discovery=False)
        check("S3d other settings can still be changed while the link is off (200)", r.status_code == 200 and jb(r).get("discovery") is False)
        r = http("POST", T.base + "/lan/code", json={})
        check("S3e /lan/code while off -> 409 lan_off", r.status_code == 409 and jb(r).get("code") == "lan_off")
        text = http("GET", T.base + "/lan").text + r.text + http("GET", T.base + "/hello").text
        ips = re.findall(r"\b\d{1,3}(?:\.\d{1,3}){3}\b", text)
        check("S3f no public IP address appears in any response (only the loopback bind)", all(lan._source_allowed(i) for i in ips), ips)
    finally:
        T.stop()
        T.release_ports()
    T = Stub("net1", env={"HOEHWA_LAN_ASSUME_PRIVATE": "1"}).start()
    try:
        st0 = get_lan(T)
        r = set_lan(T, enabled=True, port=T.lan_port, discovery_port=T.udp_port)
        check("S3g behind a router (hook: private address present): network_safe true and the link turns on",
              st0.get("network_safe") is True and r.status_code == 200 and jb(r).get("listening") is True)
        r = set_lan(T, discovery=False)
        check("S3h changing a setting while it is already on is not blocked", r.status_code == 200)
    finally:
        T.stop()
        T.release_ports()
    have = bool(lan.private_addresses())
    T = Stub("net2", env={"HOEHWA_LAN_ASSUME_PRIVATE": None}).start()      # no override: the real answer for this PC
    try:
        st0 = get_lan(T)
        r = set_lan(T, enabled=True, port=T.lan_port, discovery_port=T.udp_port)
        check("S3i without the hook the real network decides (%s on this PC)" % ("private address present -> allowed" if have else "no private address -> refused 409"),
              st0.get("network_safe") is have and r.status_code == (200 if have else 409) and (have or jb(r).get("code") == "no_private_network"),
              (have, st0.get("network_safe"), r.status_code))
    finally:
        T.stop()
        T.release_ports()
    T = Stub("net3", env={"HOEHWA_LAN_ASSUME_PRIVATE": "0"}, enabled=True).start()
    try:
        st = get_lan(T)
        check("S3j saved enabled=true but no private address at boot: stays off, says why, port closed",
              st.get("enabled") is False and st.get("listening") is False and "공유기" in st.get("error", "") and connect_code("127.0.0.1", T.lan_port) != 0)
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
        set_lan(T, enabled=True, port=T.lan_port, discovery_port=T.udp_port)
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
        set_lan(T, enabled=True, port=T.lan_port, discovery_port=T.udp_port)
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
        set_lan(T, enabled=True, port=T.lan_port, discovery_port=T.udp_port)
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


def main():
    try:
        unit_checks()
        unit_security()
        unit_discovery()
        ip2, ip2_private = None, bool(lan.private_addresses())     # no 0.0.0.0 bind in tests, so no non-loopback address can be reached
        print("\nprivate IPv4 addresses on this PC: %s (non-loopback reachability is not tested: tests bind 127.0.0.1 only)" % ("yes" if ip2_private else "none"))
        if EXTERNAL:
            lp, up = _arg("--lan-port"), _arg("--udp-port")
            if not lp or not up:
                sys.exit("--base mode needs --lan-port and --udp-port (free ports for the link of that server)")
            T = Ext(EXTERNAL, int(lp), int(up))
            set_lan(T, enabled=False)       # start from "off, nobody paired" (this is a test server: it is yours to reset)
            http("POST", T.base + "/lan/devices/revoke", json={"all": True})
            core(T, ip2, ip2_private)
            for n in ("B-10b expiry", "B-16 restart persistence", "rate limit"):
                skip(n, "needs to start/kill a server: only in self-hosted mode")
        else:
            T = scenario_core_stub(ip2, ip2_private)
            scenario_ttl()
            scenario_netsafe()
            scenario_slow()
            scenario_hdr()
            scenario_acl()
            scenario_restart()
            scenario_rate()
            scenario_logs(sorted(os.path.join(WORK, f) for f in os.listdir(WORK) if f.startswith("stub_")))
    finally:
        for s in list(Stub.live):
            s.stop()
    n = len(results)
    k = sum(1 for _, ok in results if ok)
    still = [s for s in Stub.live]
    print()
    if k == n and not skips and not still and n >= 27:
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
