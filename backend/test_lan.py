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
    for host in ("127.0.0.1", "0.0.0.0"):
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
        s.bind(("0.0.0.0", port))
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
        env.pop("HOEHWA_TEST_HOOKS", None)
        env.pop("HOEHWA_LAN_CODE_TTL", None)
        env.update(self.env)
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
        skip("B-03c non-loopback refuse", "no non-loopback IPv4 on this PC")
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
    if not ip2_private:
        note("B-11 private-IP variant NOT verified", "this PC has no private IPv4 (only %s); the non-loopback checks used that address instead" % (ip2 or "none"))
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
    T = Stub("ttl2", env={"HOEHWA_LAN_CODE_TTL": "2"}).start()    # the variable is ignored without HOEHWA_TEST_HOOKS=1
    try:
        r = set_lan(T, enabled=True, port=T.lan_port, discovery_port=T.udp_port)
        check("HOEHWA_LAN_CODE_TTL is ignored without HOEHWA_TEST_HOOKS=1 (expires_in ~300)", 295 <= (jb(r).get("pairing") or {}).get("expires_in", 0) <= 300)
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
    # bound to 0.0.0.0 on purpose: the non-loopback address must reach it (tokens are required for everything but /hello,/pair,/lan/proof)
    T = Stub("core", lan_bind="0.0.0.0").start()
    try:
        core(T, ip2, ip2_private)
    finally:
        T.stop()
        T.release_ports()
    return T


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
        ip2, ip2_private = own_ip()
        print("\nnon-loopback address used for the 'LAN' checks: %s (%s)" % (ip2 or "none", "private" if ip2_private else "NOT private"))
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
