# -*- coding: utf-8 -*-
"""Tests of "AI connect" (llm_opencode.py connect/disconnect/state, llm_routes.py, llm_config.py). No real OpenCode, no real login,
no real key, no network: a FAKE opencode (test_fake_opencode.py, behind a .cmd wrapper) and a small harness server (this file,
`--serve`) that mounts llm_routes the way server.py does. Contract: docs/onetouch_install_design.md 3.4 / 3.5 / 5 B1.

  .venv\\Scripts\\python.exe -X utf8 test_llm_connect.py [--work-dir DIR] [--keep]

  Starts its OWN processes on free ports in 18851-18859 (127.0.0.1 only), kills only the PIDs it started. Never touches the app's
  ports (8770, 8775, 8776), never reads or writes a real OpenCode login / config / %APPDATA% / learning record: every child gets
  its own USERPROFILE, HOME, APPDATA, LOCALAPPDATA inside the work folder, and HOEHWA_OPENCODE_EXE names the fake.
  Secret test: a unique marker key "sk-SENTINEL-<24 random>" is used in every connect / refuse / disconnect flow, then every file of
  the work folder, every response body and the fake's process dump are searched: SENTINEL_LEAK 0 is required. The search is
  proven to work: a harness run with a deliberate log-the-key mutation must make it find the key.

Last line:  LLM_CONNECT_TEST PASS n/n   (exit 0)   |   LLM_CONNECT_TEST FAIL k/n   (exit 1)
The marker key is never printed.
"""
import asyncio
import hashlib
import json
import os
import re
import secrets
import shutil
import socket
import string
import subprocess
import sys
import tempfile
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

APP_PORTS = (8700 + 70, 8700 + 75, 8700 + 76)   # the app's own ports, written this way on purpose: tests must never use them
PORT_LO, PORT_HI = 18851, 18859
FAKE_INSTALL = r'''
import json, os, sys, time
a = sys.argv[1:]
pf = a[a.index("--progress-file") + 1]
with open(os.environ["HOEHWA_FAKE_INSTALL_RUNS"], "a", encoding="utf-8") as f:
    f.write(json.dumps({"pid": os.getpid(), "args": [x for x in a if x not in (a[0], a[1])]}) + "\n")
try:
    ctl = json.load(open(os.environ["HOEHWA_FAKE_INSTALL_CTL"], encoding="utf-8"))
except Exception:
    ctl = {}
fail = ctl.get("mode") == "fail"
for p in range(0, 101, 10):
    with open(pf + ".tmp", "w", encoding="utf-8") as f:
        json.dump({"pct": p}, f)
    for _ in range(50):          # the reader may hold the file open for a moment: rename fails on Windows then
        try:
            os.replace(pf + ".tmp", pf)
            break
        except OSError:
            time.sleep(0.02)
    time.sleep(0.25)
    if fail and p >= 40:
        print("TOOL opencode FAIL hash 받은 파일의 해시가 달라요 (시험)")
        print("TOOL_RESULT FAIL")
        sys.exit(30)
print("TOOL opencode OK 1.19.0 somewhere")
print("TOOL_RESULT OK")
'''


# ==============================================================================================
# harness server (--serve): what server.py does with llm_routes, plus tiny /health /llm /ai_probe
# ==============================================================================================
def serve_main():
    import argparse
    import logging
    from contextlib import asynccontextmanager

    ap = argparse.ArgumentParser()
    ap.add_argument("--serve", action="store_true")
    ap.add_argument("--port", type=int, required=True)
    ap.add_argument("--lan-port", type=int, default=0)
    ap.add_argument("--save-file", default="")
    ap.add_argument("--devices-file", default="")
    ap.add_argument("--conn-ttl", type=float, default=0)
    ap.add_argument("--mutate-leak", action="store_true", help="TEST OF THE TEST: log the request body of PUT /auth (must be caught)")
    ap.add_argument("--mutate-trust-env", action="store_true", help="TEST OF THE TEST: let PUT /auth use the proxy variables (must be caught)")
    args = ap.parse_args()
    if args.port in APP_PORTS or args.lan_port in APP_PORTS:
        sys.exit("refusing the app's ports")
    if os.environ.get("HOEHWA_TEST_HOOKS") != "1":
        sys.exit("test hooks off")

    import uvicorn
    from fastapi import FastAPI, Request
    from fastapi.exceptions import RequestValidationError
    from fastapi.responses import JSONResponse
    from starlette.exceptions import HTTPException as StarletteHTTPException

    import lan
    import llm_common
    import llm_config
    import llm_fallback
    import llm_opencode
    import llm_routes

    logging.basicConfig(level=logging.DEBUG, stream=sys.stderr, format="%(asctime)s %(levelname)s %(name)s %(message)s")
    log = logging.getLogger("llmtest")
    llm_opencode.init(log=log)
    if args.conn_ttl:
        llm_opencode.CONN_TTL = args.conn_ttl
    if args.mutate_leak:
        orig_put = llm_opencode._http.put

        def leaky(url, **kw):
            log.info("DEBUG request body: %s", kw.get("json"))          # the _Secret repr hides the key here ...
            log.info("DEBUG key: %s", kw.get("json", {}).get("key"))    # ... and so does a plain %s (str() is masked too) ...
            log.info("DEBUG key: " + kw.get("json", {}).get("key"))     # ... but concatenation hands out the real text: the deliberate leak
            return orig_put(url, **kw)
        llm_opencode._http.put = leaky
    if args.mutate_trust_env:
        orig_put2 = llm_opencode._http.put

        def proxied(url, **kw):
            llm_opencode._http.trust_env = True        # what removing `_http.trust_env = False` would do
            try:
                return orig_put2(url, **kw)
            finally:
                llm_opencode._http.trust_env = False
        llm_opencode._http.put = proxied

    CFG = {"llm_provider": "ollama", "llm_model": "qwen3:8b", "ollama_url": "http://127.0.0.1:11434", "keep_alive": "30m",
           "num_ctx": 6144, "stt": {"device": "cpu"}}
    llm_config.apply(CFG)
    if args.lan_port:
        CFG["lan"] = dict(lan.DEFAULT_LAN, enabled=True, port=args.lan_port)
    else:
        CFG["lan"] = dict(lan.DEFAULT_LAN, enabled=False)

    class ApiError(Exception):
        def __init__(self, msg, status=400, format_error=False, code=""):
            self.msg, self.status, self.format_error, self.code = msg, status, format_error, code

    def save_config(cfg):
        if args.save_file:
            with open(args.save_file, "w", encoding="utf-8") as f:
                json.dump({k: v for k, v in cfg.items() if k != "lan"}, f)

    @asynccontextmanager
    async def lifespan(app_):
        lan.start_if_enabled()
        llm_opencode.prestart()
        print("SERVE_READY pid=%d port=%d" % (os.getpid(), args.port), flush=True)
        yield
        lan.shutdown()
        llm_opencode.stop()

    app = FastAPI(title="llm connect test harness", lifespan=lifespan)
    lan.attach(app, CFG, lambda cfg: None, log, HERE, devices_file=args.devices_file or None, persist=False, auto_start=True)
    llm_routes.init(CFG, log, ApiError, lan._local_only, lambda: llm_fallback.status("opencode"), save_config)
    app.include_router(llm_routes.router)

    @app.exception_handler(ApiError)
    async def _api_error(request: Request, exc: ApiError):
        body = {"error": exc.msg}
        if exc.code:
            body["code"] = exc.code
        return JSONResponse(body, status_code=exc.status)

    @app.exception_handler(RequestValidationError)
    async def _validation_error(request: Request, exc: RequestValidationError):
        return JSONResponse({"error": "요청 형식이 올바르지 않아요."}, status_code=422)

    @app.exception_handler(StarletteHTTPException)
    async def _http_error(request: Request, exc: StarletteHTTPException):
        return JSONResponse({"error": "요청을 처리할 수 없어요."}, status_code=exc.status_code)

    @app.get("/health")
    def health():
        st = llm_opencode.state()
        return {"ok": True, "llm": st == "ready", "llm_state": st}

    @app.get("/llm")
    def get_llm():
        st = llm_opencode.state()
        proc = llm_opencode._state.get("proc")
        return {"provider": CFG.get("llm_provider"), "state": st, "installed": llm_opencode.installed(),
                "connected": llm_opencode.connected() is True, "login_url": llm_opencode.LOGIN_URL,
                "notice": "ollama_removed" if CFG.get(llm_config.MARK) else "",
                "running": llm_opencode.running(), "opencode_pid": proc.pid if proc is not None else None,
                "cfg_keys": sorted(k for k in CFG if k != "lan")}

    @app.post("/ai_probe")
    def ai_probe():
        try:
            llm_opencode.call_json(CFG, [{"role": "user", "content": "hi"}], {"type": "object"})
        except llm_common.LlmError as e:
            raise ApiError(e.msg, e.status, code=llm_opencode.ERROR_CODES.get(e.kind, ""))
        return {"ok": True}

    uvicorn.run(app, host="127.0.0.1", port=args.port, log_level="info")


if "--serve" in sys.argv:
    serve_main()
    sys.exit(0)

import requests  # noqa: E402

WORK = None
results = []
RESPONSES = []        # (url, status, body text, headers text) of every call: searched for the marker key
INSTS = []


def _arg(name, default=None):
    if name in sys.argv:
        i = sys.argv.index(name)
        if i + 1 < len(sys.argv):
            return sys.argv[i + 1]
    return default


def check(name, cond, detail=""):
    results.append((name, bool(cond)))
    print("  [%s] %s%s" % ("PASS" if cond else "FAIL", name, (" -- " + str(detail)) if detail != "" else ""), flush=True)
    return bool(cond)


def sha(s):
    return hashlib.sha256(s.encode("utf-8")).hexdigest()


SESSION = requests.Session()
SESSION.trust_env = False      # the test client talks to 127.0.0.1 and sends the marker key: never through a proxy from the environment


def call(method, url, **kw):
    kw.setdefault("timeout", 90)
    r = SESSION.request(method, url, **kw)
    RESPONSES.append((url, r.status_code, r.text, str(dict(r.headers))))
    return r


def jb(r):
    try:
        return r.json()
    except Exception:
        return {}


def tcp_free(port):
    """True when nothing listens on 127.0.0.1:port (a connect is refused). A bind() test is wrong on Windows: connections of a
    server that was just stopped sit in TIME_WAIT for a while and make bind fail although nobody listens."""
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(1.0)
    try:
        return s.connect_ex(("127.0.0.1", port)) != 0
    finally:
        s.close()


_USED = set()
_EVER = set()      # every port this run used (never released): checked closed at the end


def pick():
    for p in range(PORT_LO, PORT_HI + 1):
        if p not in _USED and tcp_free(p):
            _USED.add(p)
            _EVER.add(p)
            return p
    sys.exit("no free port in %d-%d" % (PORT_LO, PORT_HI))


MARKERS = ("--serve", "fake_opencode.py", "opencode.cmd", "fake_install_tools.py")


def procs_under(folder):
    """[(pid, command line)] of the processes THIS TEST started under `folder`: command line names the folder AND carries one of
    our own markers (harness --serve, fake opencode, its .cmd wrapper, fake installer). Never this process or one of its
    ancestors (the venv python.exe launcher is the parent of the real interpreter and may show the same command line).
    Identity by command line, never by a remembered PID alone: a dead PID may already belong to someone else."""
    ps = "Get-CimInstance Win32_Process | ForEach-Object { '{0}|{1}|{2}' -f $_.ProcessId, $_.ParentProcessId, $_.CommandLine }"
    r = subprocess.run(["powershell", "-NoProfile", "-Command", ps], capture_output=True, creationflags=0x08000000, timeout=90)
    rows, parent = [], {}
    for line in r.stdout.decode("utf-8", "replace").splitlines():
        pid, _, rest = line.partition("|")
        ppid, _, cmd = rest.partition("|")
        if pid.strip().isdigit() and ppid.strip().isdigit():
            parent[int(pid)] = int(ppid)
            rows.append((int(pid), cmd))
    safe, cur = {os.getpid()}, os.getpid()
    while cur in parent and parent[cur] not in safe and parent[cur] > 0:
        cur = parent[cur]
        safe.add(cur)
    return [(pid, cmd) for pid, cmd in rows if pid not in safe and folder in cmd and any(m in cmd for m in MARKERS)]


def kill_pid(pid):
    subprocess.run(["taskkill", "/PID", str(pid), "/T", "/F"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                   creationflags=0x08000000)


def proxy_clean(sink, key):
    """True when the fake proxy saw nothing: no connection at all and not the key"""
    return sink.count == 0 and key.encode() not in sink.data


def scan_leaks(root, patterns, skip=()):
    """[(relative file, pattern)] of every file under root that contains one of the byte patterns"""
    hits = []
    for dp, dn, fn in os.walk(root):
        for n in fn:
            p = os.path.join(dp, n)
            if any(p.startswith(s) for s in skip):
                continue
            try:
                data = open(p, "rb").read()
            except OSError:
                continue
            for pat in patterns:
                if pat in data:
                    hits.append((os.path.relpath(p, root), pat[:4] + b".."))
                    break
    return hits


class ProxySink:
    """a fake HTTP proxy: accepts connections, counts them, keeps what they sent (to look for the key), answers nothing"""

    def __init__(self):
        self.port = pick()
        self.count = 0
        self.data = b""
        self.lock = threading.Lock()
        self.srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.srv.bind(("127.0.0.1", self.port))
        self.srv.listen(8)
        self.srv.settimeout(0.3)
        self.stop_flag = False
        self.th = threading.Thread(target=self._run, daemon=True)
        self.th.start()

    def _run(self):
        while not self.stop_flag:
            try:
                c, _ = self.srv.accept()
            except OSError:
                continue
            with self.lock:
                self.count += 1
            c.settimeout(0.5)
            try:
                while True:
                    d = c.recv(65536)
                    if not d:
                        break
                    with self.lock:
                        self.data += d
            except OSError:
                pass
            finally:
                c.close()

    def close(self):
        self.stop_flag = True
        self.th.join(5)
        self.srv.close()
        _USED.discard(self.port)


class Inst:
    """one harness server + its own fake-opencode state, in its own folder"""

    def __init__(self, name, fake="ok", conn_ttl=0, lan=False, logged_in=False, install=None, mutate=False, ctl=None, no_install_script=False, proxy_port=0, mutate_trust=False):
        self.name = name
        self.dir = os.path.join(WORK, name)
        self.state = os.path.join(self.dir, "state")
        self.logs = os.path.join(self.dir, "logs")
        self.ctl_path = os.path.join(self.state, "control.json")
        self.lan = lan
        self.proc = None
        self.pid = None
        self.port = pick()
        self.lan_port = pick() if lan else 0
        self.fake = fake
        for d in (self.dir, self.state, self.logs, os.path.join(self.dir, "home"), os.path.join(self.dir, "appdata"),
                  os.path.join(self.dir, "localappdata"), os.path.join(self.dir, "approot")):
            os.makedirs(d, exist_ok=True)
        self.write_ctl(**(ctl or {}))
        if logged_in:
            with open(os.path.join(self.state, "fake_login.json"), "w") as f:
                json.dump({"sha256": sha("preexisting-login")}, f)
        exe = os.path.join(WORK, "bin", "opencode.cmd") if fake == "ok" else os.path.join(self.dir, "no_such_dir", "opencode.exe")
        env = {k: v for k, v in os.environ.items() if not k.upper().startswith(("OPENCODE", "HOEHWA_")) and k.upper() not in
               ("HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY")}
        if proxy_port:     # a proxy that must never be used (a plain listener of this test that counts connections)
            for k in ("HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "http_proxy", "https_proxy", "all_proxy"):
                env[k] = "http://127.0.0.1:%d" % proxy_port
        env.update(HOEHWA_TEST_HOOKS="1", HOEHWA_OPENCODE_EXE=exe, HOEHWA_FAKE_OC_STATE=self.state, HOEHWA_LOG_DIR=self.logs,
                   HOEHWA_LAN_ASSUME_TAILSCALE="127.0.0.1", USERPROFILE=os.path.join(self.dir, "home"), HOME=os.path.join(self.dir, "home"),
                   APPDATA=os.path.join(self.dir, "appdata"), LOCALAPPDATA=os.path.join(self.dir, "localappdata"),
                   HOEHWA_APP_ROOT=os.path.join(self.dir, "approot"), PYTHONUTF8="1")
        if install is not None:
            self.install_ctl = os.path.join(self.dir, "install_ctl.json")
            self.install_runs = os.path.join(self.dir, "install_runs.log")
            with open(self.install_ctl, "w") as f:
                json.dump({"mode": install}, f)
            env.update(HOEHWA_FAKE_INSTALL_CTL=self.install_ctl, HOEHWA_FAKE_INSTALL_RUNS=self.install_runs,
                       HOEHWA_TOOLS_LOCK=os.path.join(WORK, "bin", "tools.lock.json"))
            env["HOEHWA_INSTALL_TOOLS_PY"] = os.path.join(WORK, "bin", "no_such_install_tools.py") if no_install_script else os.path.join(WORK, "bin", "fake_install_tools.py")
        self.env = env
        self.save_file = os.path.join(self.dir, "config_saved.json")
        self.log_path = os.path.join(self.dir, "server.log")
        self.conn_ttl, self.mutate, self.mutate_trust = conn_ttl, mutate, mutate_trust
        self.cmd = self._mkcmd()

    def _mkcmd(self):
        cmd = [sys.executable, "-X", "utf8", os.path.abspath(__file__), "--serve", "--port", str(self.port), "--save-file", self.save_file,
               "--devices-file", os.path.join(self.dir, "lan_devices.json")]
        if self.lan:
            cmd += ["--lan-port", str(self.lan_port)]
        if self.conn_ttl:
            cmd += ["--conn-ttl", str(self.conn_ttl)]
        if self.mutate:
            cmd += ["--mutate-leak"]
        if self.mutate_trust:
            cmd += ["--mutate-trust-env"]
        return cmd

    def write_ctl(self, **kw):
        with open(self.ctl_path, "w", encoding="utf-8") as f:
            json.dump(kw, f)

    def start(self, wait_health=True):
        for attempt in range(3):
            out = open(self.log_path, "wb")
            self.proc = subprocess.Popen(self.cmd, env=self.env, stdin=subprocess.DEVNULL, stdout=out, stderr=subprocess.STDOUT,
                                         creationflags=0x08000000)
            out.close()
            self.pid = self.proc.pid
            if self not in INSTS:
                INSTS.append(self)
            t0 = time.time()
            while wait_health and time.time() - t0 < 40:
                if self.proc.poll() is not None:
                    break
                try:
                    if SESSION.get(self.url("/health"), timeout=2).status_code == 200:
                        return True
                except requests.RequestException:
                    pass
                time.sleep(0.3)
            if not wait_health:
                return True
            if self.proc.poll() is None:
                return False
            # it ended at once (a port was taken by someone else between the check and the bind): other ports, once more
            _USED.discard(self.port)
            _USED.discard(self.lan_port)
            self.port = pick()
            self.lan_port = pick() if self.lan else 0
            self.cmd = self._mkcmd()
        return False

    def url(self, path):
        return "http://127.0.0.1:%d%s" % (self.port, path)

    def lan_url(self, path):
        return "http://127.0.0.1:%d%s" % (self.lan_port, path)

    def post(self, path, body=None, **kw):
        return call("POST", self.url(path), json=body if body is not None else {}, **kw)

    def get(self, path, **kw):
        return call("GET", self.url(path), **kw)

    def fake_requests(self):
        try:
            return open(os.path.join(self.state, "requests.log"), encoding="utf-8").read().splitlines()
        except OSError:
            return []

    def puts(self):
        return len([l for l in self.fake_requests() if l.startswith("PUT /auth/opencode")])

    def received(self):
        try:
            return json.load(open(os.path.join(self.state, "received.json"), encoding="utf-8"))
        except (OSError, ValueError):
            return []

    def fake_pid(self):
        try:
            return json.load(open(os.path.join(self.state, "proc_dump.json"), encoding="utf-8")).get("pid")
        except (OSError, ValueError):
            return None

    def server_log(self):
        try:
            return open(self.log_path, encoding="utf-8", errors="replace").read()
        except OSError:
            return ""

    def stop(self):
        if self.proc is not None and self.proc.poll() is None:
            kill_pid(self.pid)           # the harness we started (we hold its handle: the PID cannot be someone else's) and its children
        if self.proc is not None:
            try:
                self.proc.wait(timeout=15)
            except Exception:
                pass
        for pid, _ in procs_under(self.dir):     # a fake opencode / installer of this instance that outlived the tree kill
            kill_pid(pid)
        self.proc = None
        _USED.discard(self.port)
        _USED.discard(self.lan_port)


def key_for(label):
    return "sk-SENTINEL-" + "".join(secrets.choice(string.ascii_letters + string.digits) for _ in range(24))


_SUMMARY = [False]


def main():
    abort = False
    try:
        _main()
    finally:
        abort = not _SUMMARY[0]
        if abort:
            print("LLM_CONNECT_TEST ABORTED (no summary line: this is NOT a pass)", flush=True)
        for i in INSTS:        # never leave a harness or fake behind, whatever happened
            if i.proc is not None and i.proc.poll() is None:
                kill_pid(i.pid)
        if WORK:
            for pid, _ in procs_under(WORK):
                kill_pid(pid)
        if abort:
            os._exit(3)


def _main():
    global WORK
    WORK = _arg("--work-dir") or tempfile.mkdtemp(prefix="llm_connect_test_")
    os.makedirs(WORK, exist_ok=True)
    WORK = os.path.abspath(WORK)
    if os.listdir(WORK):
        sys.exit("--work-dir must be empty: " + WORK)
    keep = "--keep" in sys.argv
    backend_cfg = os.path.join(HERE, "config.json")
    cfg_hash0 = hashlib.sha256(open(backend_cfg, "rb").read()).hexdigest() if os.path.isfile(backend_cfg) else ""
    KEY = key_for("main")
    KEY2 = key_for("echo")
    KEY3 = key_for("lan")
    KEY4 = key_for("proxy")
    KEY5 = key_for("proxymut")
    ALLKEYS = [KEY, KEY2, KEY3, KEY4]
    rnd = [k[len("sk-SENTINEL-"):].encode() for k in ALLKEYS]
    patterns = [b"SENTINEL"] + rnd + [k.encode() for k in ALLKEYS]

    # ---- fake opencode behind a .cmd wrapper (ASCII work folder; the wrapper is written in the console code page)
    bindir = os.path.join(WORK, "bin")
    os.makedirs(bindir)
    shutil.copy(os.path.join(HERE, "test_fake_opencode.py"), os.path.join(bindir, "fake_opencode.py"))
    with open(os.path.join(bindir, "fake_install_tools.py"), "w", encoding="utf-8") as f:
        f.write(FAKE_INSTALL)
    with open(os.path.join(bindir, "tools.lock.json"), "w") as f:
        f.write('{"schema": 1}')
    with open(os.path.join(bindir, "opencode.cmd"), "w", encoding="oem", newline="\r\n") as f:
        f.write('@"%s" "%s" %%*\r\n' % (sys.executable, os.path.join(bindir, "fake_opencode.py")))
    env0 = dict(os.environ, HOEHWA_FAKE_OC_STATE=os.path.join(WORK, "wrapcheck"))
    r = subprocess.run([os.path.join(bindir, "opencode.cmd"), "--version"], capture_output=True, text=True, env=env0, timeout=30)
    check("fake opencode wrapper runs", r.stdout.strip() == "1.19.0-fake", (r.stdout + r.stderr)[:120])

    # =========================================================================== B1-10 llm_config (import only llm_config)
    print("== B1-10 llm_config.migrate")
    import llm_config
    old = {"llm_provider": "ollama", "llm_model": "qwen3:8b", "ollama_url": "http://127.0.0.1:11434", "keep_alive": "30m",
           "num_ctx": 6144, "stt": {"device": "cpu"}}
    snap = json.dumps(old, sort_keys=True)
    new, notice = llm_config.migrate(old)
    check("B1-10 ollama -> opencode, four keys gone, stt kept, notice ollama_removed, llm_migrated_from=ollama",
          new.get("llm_provider") == "opencode" and not (set(llm_config.OLD_KEYS) & set(new)) and new.get("stt") == {"device": "cpu"}
          and notice == "ollama_removed" and new.get("llm_migrated_from") == "ollama", new)
    check("B1-10 migrate does not change its input", json.dumps(old, sort_keys=True) == snap)
    new, notice = llm_config.migrate({"llm_provider": "opencode"})
    check("B1-10 opencode -> notice empty, nothing added", notice == "" and new == {"llm_provider": "opencode"}, (new, notice))
    new, notice = llm_config.migrate({"llm_provider": "zzz"})
    check("B1-10 unknown value -> opencode", new.get("llm_provider") == "opencode" and notice == "ollama_removed")
    new, notice = llm_config.migrate({"llm_provider": "openai_api", "llm_model": "x"})
    check("B1-10 openai_api (developer engine) is kept", new.get("llm_provider") == "openai_api" and "llm_model" not in new and notice == "")
    new, notice = llm_config.migrate({"llm_provider": "opencode", "llm_migrated_from": "ollama"})
    check("B1-10 an unacknowledged earlier move keeps the notice", notice == "ollama_removed")
    c = {"llm_provider": "ollama"}
    n1, changed = llm_config.apply(c)
    check("B1-10 apply() works in place; ack() removes the mark", n1 == "ollama_removed" and changed and c["llm_provider"] == "opencode"
          and llm_config.ack(c) and "llm_migrated_from" not in c and not llm_config.ack(c))

    # =========================================================================== in-process pieces
    print("== in-process: scrub, key format, exe() hook")
    import llm_common
    import llm_opencode
    import llm_routes
    e = llm_opencode._scrub(llm_common.LlmError("bad credential " + KEY + " here", 503, "auth", "raw " + KEY), KEY)
    check("an error text that echoes the key is scrubbed", KEY not in e.msg and KEY not in e.raw and "***" in e.msg)
    sec = llm_opencode._Secret(KEY)
    check("_Secret: repr, str, %s, %r and f-string all hide the value",
          all(KEY not in t for t in (repr(sec), str(sec), "%s" % sec, "%r" % sec, "{}".format(sec), f"{sec}", "%s" % ({"k": sec},))))
    check("_Secret: the real value is still there for json and str.__str__ (the PUT body must carry it)",
          json.dumps({"key": sec}) == json.dumps({"key": KEY}) and str.__str__(sec) == KEY and sec == KEY)
    cases = [("", None), ("   ", None), ("a" * 15, None), ("a" * 16, "a" * 16), ("a" * 256, "a" * 256), ("a" * 257, None),
             ("abc def ghi jkl mno", None), ("abcdefghijklmnop\nqrstuvwx", None), ("한글" * 10, None), (12345678901234567890, None),
             (None, None), ("  " + "b" * 20 + "\r\n", "b" * 20), ("a" * 15 + "é", None)]
    check("clean_key table", all(llm_routes.clean_key(v) == want for v, want in cases),
          [i for i, (v, w) in enumerate(cases) if llm_routes.clean_key(v) != w])
    os.environ["HOEHWA_TEST_HOOKS"] = "1"
    os.environ["HOEHWA_OPENCODE_EXE"] = os.path.join(WORK, "does_not_exist.exe")
    check("exe() with a hook path that does not exist is None (never falls through to a real OpenCode)", llm_opencode.exe() is None)
    os.environ["HOEHWA_OPENCODE_EXE"] = os.path.join(bindir, "opencode.cmd")
    check("exe() with a hook path that exists returns it", llm_opencode.exe() == os.path.join(bindir, "opencode.cmd"))
    del os.environ["HOEHWA_TEST_HOOKS"]
    p = llm_opencode.exe()
    expected = next((c for c in (os.path.join(HERE, "tools", "opencode", "opencode.exe"),
                                 os.path.join(os.environ.get("APPDATA", ""), "npm", "node_modules", "opencode-ai", "bin", "opencode.exe"))
                     if os.path.isfile(c)), None) or shutil.which("opencode.exe")
    check("without the test hooks HOEHWA_OPENCODE_EXE (an existing file) is ignored: exe() is exactly the normal search result",
          os.path.isfile(os.path.join(bindir, "opencode.cmd")) and p == expected and p != os.path.join(bindir, "opencode.cmd"), (p, expected))
    del os.environ["HOEHWA_OPENCODE_EXE"]
    check("source: no 11434 / api/tags in llm_opencode.py or llm_routes.py",
          not any(s in open(os.path.join(HERE, f), encoding="utf-8").read() for f in ("llm_opencode.py", "llm_routes.py") for s in ("11434", "api/tags")))
    src = open(os.path.join(HERE, "llm_opencode.py"), encoding="utf-8").read() + open(os.path.join(HERE, "llm_routes.py"), encoding="utf-8").read()
    check("source: no auth.json / .local path string in llm_opencode.py or llm_routes.py (the app never opens OpenCode's auth file)",
          not re.search(r"""["']auth\.json["']""", src) and ".local" not in src)
    logs = [l for l in open(os.path.join(HERE, "llm_routes.py"), encoding="utf-8").read().splitlines() if "_log()." in l]
    check("source: no log line in llm_routes.py takes the key", logs and not any(re.search(r"\bkey\b", l) for l in logs), len(logs))

    # =========================================================================== main instance: connect flow, bad input, LAN
    print("== B1-2 connect flow")
    A = Inst("main", lan=True)
    check("harness server starts", A.start(), A.server_log()[-300:])
    g = jb(A.get("/llm"))
    check("B1-2 not logged in: state=not_connected, installed, connected=false",
          g.get("state") == "not_connected" and g.get("installed") is True and g.get("connected") is False, g)
    check("harness GET /health says llm_state not_connected", jb(A.get("/health")).get("llm_state") == "not_connected")
    check("old config moved: provider opencode, notice ollama_removed, old keys gone",
          g.get("provider") == "opencode" and g.get("notice") == "ollama_removed" and not ({"llm_model", "ollama_url", "keep_alive", "num_ctx"} & set(g.get("cfg_keys", []))), g)
    r = A.post("/ai_probe")
    check("a call before connecting -> 503 ai_not_connected (Korean text), no key anywhere",
          r.status_code == 503 and jb(r).get("code") == "ai_not_connected" and "연결" in jb(r).get("error", ""), r.text[:200])
    t0 = time.time()
    r = A.post("/llm/connect", {"key": KEY})
    b = jb(r)
    check("B1-2 POST /llm/connect -> 200 ok:true state=ready tested=true", r.status_code == 200 and b.get("ok") is True and b.get("state") == "ready"
          and b.get("tested") is True and isinstance(b.get("seconds"), (int, float)), (r.status_code, b))
    g = jb(A.get("/llm"))
    check("B1-2 after connecting GET /llm: state=ready connected=true", g.get("state") == "ready" and g.get("connected") is True, g)
    check("B1-5 the fake received the marker key (SHA-256 equal)", sha(KEY) in [x.get("sha256") for x in A.received()])
    check("a call after connecting works", A.post("/ai_probe").status_code == 200)
    check("harness GET /health llm_state ready", jb(A.get("/health")).get("llm_state") == "ready")
    fp = A.fake_pid()
    dump = json.load(open(os.path.join(A.state, "proc_dump.json"), encoding="utf-8"))
    check("B1-5 the key is not in the fake serve's command line or environment (hash compare)", fp and sha(KEY) not in dump["argv"] + dump["env"])
    check("B1-13 server log: 'opencode exe:' is the fake, no Roaming\\npm",
          any("opencode exe:" in l and "opencode.cmd" in l and "npm" not in l and "Roaming" not in l for l in A.server_log().splitlines()))
    check("B1-13 the real home / appdata were not used (server's own folders hold the work dir)",
          os.path.isfile(os.path.join(A.dir, "localappdata", "hoehwa-practice", "opencode", "work", "opencode.json")))

    print("== B1-3 / B1-4 refused key, limit, overload, model gone, echo")
    A.write_ctl(test_call="401")
    r = A.post("/llm/connect", {"key": KEY})
    b = jb(r)
    check("B1-3 test call 401 -> 503 code=ai_auth, Korean error", r.status_code == 503 and b.get("code") == "ai_auth"
          and re.search("[가-힣]", b.get("error", "")) and "키" in b.get("error", ""), (r.status_code, b))
    A.write_ctl(test_call="429")
    r = A.post("/llm/connect", {"key": KEY})
    b = jb(r)
    check("B1-4 test call 429 -> 200 ok, tested=false, note", r.status_code == 200 and b.get("ok") is True and b.get("tested") is False and b.get("note"), (r.status_code, b))
    A.write_ctl(test_call="529")
    r = A.post("/llm/connect", {"key": KEY})
    check("overload (529) -> 200 tested=false", r.status_code == 200 and jb(r).get("tested") is False, (r.status_code, jb(r)))
    A.write_ctl(test_call="model_not_found")
    r = A.post("/llm/connect", {"key": KEY})
    check("R3 model gone -> 503 ai_auth", r.status_code == 503 and jb(r).get("code") == "ai_auth", (r.status_code, jb(r)))
    A.write_ctl(test_call="echo_key")
    r = A.post("/llm/connect", {"key": KEY2})
    check("an upstream error that echoes the key -> 503 ai_auth and the answer has no key", r.status_code == 503 and jb(r).get("code") == "ai_auth"
          and KEY2 not in r.text and "SENTINEL" not in r.text, r.status_code)
    A.write_ctl(put_status=500)
    r = A.post("/llm/connect", {"key": KEY})
    check("OpenCode refusing PUT /auth (500) -> 502 ai_unavailable, no key", r.status_code in (502, 503) and jb(r).get("code") == "ai_unavailable" and KEY not in r.text, (r.status_code, jb(r)))
    A.write_ctl(put_status=400)
    r = A.post("/llm/connect", {"key": KEY})
    check("OpenCode saying 400 to the key -> 503 ai_auth", r.status_code == 503 and jb(r).get("code") == "ai_auth", (r.status_code, jb(r)))
    A.write_ctl()

    print("== B1-6 bad input (no PUT /auth reaches the fake)")
    good = "sk-" + "x" * 20
    puts0 = A.puts()
    js = {"Content-Type": "application/json"}
    rows = [
        ("empty string", dict(data=json.dumps({"key": ""}), headers=js), 400, "bad_key_format"),
        ("spaces only", dict(data=json.dumps({"key": "     "}), headers=js), 400, "bad_key_format"),
        ("15 chars", dict(data=json.dumps({"key": "a" * 15}), headers=js), 400, "bad_key_format"),
        ("257 chars", dict(data=json.dumps({"key": "a" * 257}), headers=js), 400, "bad_key_format"),
        ("space inside", dict(data=json.dumps({"key": "sk-aaaaaaaaaa bbbbbbbbbb"}), headers=js), 400, "bad_key_format"),
        ("newline inside", dict(data=json.dumps({"key": "sk-aaaaaaaaaa\nbbbbbbbbbb"}), headers=js), 400, "bad_key_format"),
        ("Korean", dict(data=json.dumps({"key": "한글한글한글한글한글한글한글한글"}), headers=js), 400, "bad_key_format"),
        ("key is a number", dict(data=json.dumps({"key": 12345678901234567890}), headers=js), 400, "bad_key_format"),
        ("key is a list", dict(data=json.dumps({"key": [good]}), headers=js), 400, "bad_key_format"),
        ("no key", dict(data=json.dumps({"other": good}), headers=js), 400, "bad_key_format"),
        ("body is a list", dict(data=json.dumps([good]), headers=js), 400, "bad_key_format"),
        ("broken JSON", dict(data=b'{"key": ', headers=js), 400, "bad_key_format"),
        ("empty body", dict(data=b"", headers=js), 400, "bad_key_format"),
        ("huge body", dict(data=json.dumps({"key": good, "pad": "p" * 5000}), headers=js), 400, "bad_key_format"),
        ("Content-Type text/plain", dict(data=json.dumps({"key": good}), headers={"Content-Type": "text/plain"}), 403, "bad_origin"),
        ("Origin evil", dict(data=json.dumps({"key": good}), headers=dict(js, Origin="http://evil.example")), 403, "bad_origin"),
        ("Host evil", dict(data=json.dumps({"key": good}), headers=dict(js, Host="evil.example")), 403, "bad_origin"),
    ]
    for name, kw, st, code in rows:
        r = call("POST", A.url("/llm/connect"), **kw)
        check("B1-6 %s -> %d %s" % (name, st, code), r.status_code == st and jb(r).get("code") == code, (r.status_code, r.text[:100]))
    check("B1-6 the fake received no PUT /auth for any bad row", A.puts() == puts0, (puts0, A.puts()))
    for name, path in (("disconnect", "/llm/disconnect"), ("install", "/llm/install"), ("notice/ack", "/llm/notice/ack")):
        r = call("POST", A.url(path), data=b"{}", headers={"Content-Type": "text/plain"})
        check("B1-6 POST %s with Content-Type text/plain -> 403" % path, r.status_code == 403, r.status_code)
        r = call("POST", A.url(path), data=b"{}", headers=dict(js, Origin="http://evil.example"))
        check("B1-6 POST %s with Origin evil -> 403" % path, r.status_code == 403, r.status_code)
    r = call("GET", A.url("/llm/install"), headers={"Host": "evil.example"})
    check("B1-6 GET /llm/install with Host evil -> 403", r.status_code == 403, r.status_code)
    # boundaries that must work
    r = A.post("/llm/connect", {"key": "k" * 16})
    check("boundary: 16 characters accepted", r.status_code == 200, (r.status_code, r.text[:80]))
    r = A.post("/llm/connect", {"key": "k" * 256})
    check("boundary: 256 characters accepted", r.status_code == 200, (r.status_code, r.text[:80]))
    r = A.post("/llm/connect", {"key": "  " + "m" * 20 + "\r\n"})
    check("white space around the key is cut off (the fake got the trimmed key)", r.status_code == 200 and sha("m" * 20) in [x.get("sha256") for x in A.received()])

    print("== B1-7 phone (LAN) cannot reach the endpoints")
    code = jb(A.post("/lan/code")).get("code", "")
    pr = call("POST", A.lan_url("/pair"), json={"code": code, "device_name": "Test Phone"})
    token = jb(pr).get("token", "")
    check("a phone paired over the test link", pr.status_code == 200 and token.startswith("hp1_"), pr.status_code)
    hdr = {"Authorization": "Bearer " + token}
    check("control: the same token works on an allowed path (GET /health -> 200)", call("GET", A.lan_url("/health"), headers=hdr).status_code == 200)
    puts1 = A.puts()
    for m, path, body in (("POST", "/llm/connect", {"key": KEY3}), ("POST", "/llm/disconnect", {}), ("POST", "/llm/install", {}),
                          ("GET", "/llm/install", None), ("POST", "/llm/notice/ack", {})):
        kw = {"headers": hdr}
        if body is not None:
            kw["json"] = body
        r = call(m, A.lan_url(path), **kw)
        check("B1-7 phone %s %s -> 403 lan_forbidden" % (m, path), r.status_code == 403 and jb(r).get("code") == "lan_forbidden", (r.status_code, r.text[:100]))
    check("B1-7 the fake got no PUT from the phone's attempts", A.puts() == puts1)
    r = call("POST", A.lan_url("/llm/connect"), json={"key": KEY3})
    check("B1-7 phone without a token -> 401", r.status_code == 401, r.status_code)
    # second defence, in-process: a request that carries the LAN mark never reaches the work
    from starlette.requests import Request
    import lan
    llm_routes.init({}, None, None, lan._local_only, None, None)
    called = []
    orig_connect = llm_opencode.connect
    llm_opencode.connect = lambda *a, **k: called.append(1) or {"tested": True, "seconds": 0}
    body = json.dumps({"key": good}).encode()

    async def rcv():
        return {"type": "http.request", "body": body, "more_body": False}
    scope = {"type": "http", "method": "POST", "path": "/llm/connect", "headers": [(b"host", b"127.0.0.1:1"), (b"content-type", b"application/json")],
             "client": ("127.0.0.1", 5555), "hoehwa_lan": True, "query_string": b""}
    resp = asyncio.run(llm_routes.connect_endpoint(Request(scope, rcv)))
    check("B1-7 second defence: a request marked as LAN is refused by the endpoint itself (403 local_only)",
          getattr(resp, "status_code", None) == 403 and b"local_only" in getattr(resp, "body", b"") and not called, resp)
    scope2 = dict(scope, hoehwa_lan=False, client=("203.0.113.9", 1))
    resp = asyncio.run(llm_routes.connect_endpoint(Request(scope2, rcv)))
    check("B1-7 second defence: a non-loopback address is refused", getattr(resp, "status_code", None) == 403 and not called, resp)
    scope3 = dict(scope, hoehwa_lan=False)
    resp = asyncio.run(llm_routes.connect_endpoint(Request(scope3, rcv)))
    check("control: the same request from loopback passes the guard and reaches the work", isinstance(resp, dict) and resp.get("ok") is True and called, resp)
    llm_opencode.connect = orig_connect

    print("== disconnect, notice ack")
    r = A.post("/llm/disconnect")
    b = jb(r)
    check("POST /llm/disconnect -> 200 not_connected", r.status_code == 200 and b.get("ok") is True and b.get("state") == "not_connected", (r.status_code, b))
    check("the fake's stored login is gone", not os.path.exists(os.path.join(A.state, "fake_login.json")))
    g = jb(A.get("/llm"))
    check("GET /llm after disconnect: not_connected / connected=false", g.get("state") == "not_connected" and g.get("connected") is False, g)
    r = A.post("/ai_probe")
    check("a call after disconnecting -> 503 ai_not_connected", r.status_code == 503 and jb(r).get("code") == "ai_not_connected", r.status_code)
    r = A.post("/llm/notice/ack")
    g = jb(A.get("/llm"))
    saved = json.load(open(A.save_file, encoding="utf-8")) if os.path.isfile(A.save_file) else None
    check("POST /llm/notice/ack -> notice empty and config saved without llm_migrated_from",
          r.status_code == 200 and g.get("notice") == "" and saved is not None and "llm_migrated_from" not in saved and saved.get("llm_provider") == "opencode", (g.get("notice"), saved))
    A.stop()
    check("the harness and its fake opencode are gone after stopping (no process names the instance folder)", not procs_under(A.dir), procs_under(A.dir))

    # =========================================================================== B1-8 not installed + B1-11 install
    print("== B1-8 opencode.exe missing, B1-11 /llm/install")
    N = Inst("noexe", fake="missing", install="ok")
    check("harness (no opencode.exe) starts", N.start(), N.server_log()[-300:])
    g = jb(N.get("/llm"))
    check("B1-8 state=not_installed, installed=false, server not started", g.get("state") == "not_installed" and g.get("installed") is False and g.get("running") is False, g)
    check("B1-8 /health llm_state not_installed", jb(N.get("/health")).get("llm_state") == "not_installed")
    r = N.post("/ai_probe")
    check("B1-8 call_json -> LlmError kind=not_installed -> 503 ai_not_installed", r.status_code == 503 and jb(r).get("code") == "ai_not_installed", (r.status_code, r.text[:100]))
    import llm_common as lc
    try:
        os.environ["HOEHWA_TEST_HOOKS"] = "1"
        os.environ["HOEHWA_OPENCODE_EXE"] = os.path.join(WORK, "no_such_dir", "opencode.exe")
        llm_opencode.reset_state()
        got = None
        try:
            llm_opencode.call_json({}, [{"role": "user", "content": "x"}], {"type": "object"})
        except lc.LlmError as ex:
            got = (ex.kind, ex.status)
        got2 = None
        try:
            llm_opencode.chat_json({}, "c1", "sys", [{"role": "me", "text": "hi"}], "", {"type": "object"})
        except lc.LlmError as ex:
            got2 = (ex.kind, ex.status)
        check("B1-8 in-process: call_json / chat_json raise LlmError(kind=not_installed, 503) and start no server",
              got == ("not_installed", 503) and got2 == ("not_installed", 503) and not llm_opencode.running(), (got, got2))
    finally:
        os.environ.pop("HOEHWA_OPENCODE_EXE", None)
        os.environ.pop("HOEHWA_TEST_HOOKS", None)
    r = N.post("/llm/connect", {"key": good})
    check("B1-8 POST /llm/connect without opencode.exe -> 503 ai_not_installed", r.status_code == 503 and jb(r).get("code") == "ai_not_installed", (r.status_code, jb(r)))
    check("B1-8 no fake opencode was started (no process dump, no requests)", N.fake_pid() is None and not N.fake_requests())
    g = jb(N.get("/llm/install"))
    check("B1-11 before installing: GET /llm/install idle", g.get("state") == "idle" and g.get("pct") == 0, g)
    r1 = N.post("/llm/install")
    r2 = N.post("/llm/install")
    check("B1-11 POST /llm/install twice -> both 200 running", r1.status_code == 200 and jb(r1).get("state") == "running" and r2.status_code == 200 and jb(r2).get("state") == "running", (jb(r1), jb(r2)))
    seen, states = [], []
    t0 = time.time()
    while time.time() - t0 < 30:
        g = jb(N.get("/llm/install"))
        states.append(g.get("state"))
        seen.append(g.get("pct", 0))
        if g.get("state") in ("done", "error"):
            break
        time.sleep(0.15)
    runs = [json.loads(l) for l in open(N.install_runs, encoding="utf-8").read().splitlines()] if os.path.exists(N.install_runs) else []
    check("B1-11 progress: running first, pct never decreases and grows, ends done pct=100", states[0] == "running" and "running" in states and states[-1] == "done"
          and seen == sorted(seen) and seen[-1] == 100 and any(0 < p < 100 for p in seen), (states[:3], seen[-6:]))
    check("B1-11 exactly one install process for two POSTs", len(runs) == 1, len(runs))
    check("B1-11 the install script got the lock, the app root, --only opencode and a --progress-file",
          runs and "--only" in runs[0]["args"] and "opencode" in runs[0]["args"] and "--progress-file" in runs[0]["args"], runs[:1])
    check("B1-11 the install process has exited and the progress files are cleaned up", runs and not [x for x in procs_under(bindir) if "fake_install_tools" in x[1]]
          and not [f for f in os.listdir(os.path.join(N.dir, "localappdata", "hoehwa-practice", "opencode")) if f.startswith("install_progress")])
    with open(N.install_ctl, "w") as f:
        json.dump({"mode": "fail"}, f)
    N.post("/llm/install")
    t0 = time.time()
    g = {}
    while time.time() - t0 < 30:
        g = jb(N.get("/llm/install"))
        if g.get("state") in ("done", "error"):
            break
        time.sleep(0.15)
    check("B1-11 a failing install -> state=error with the Korean reason of the tool, pct < 100", g.get("state") == "error" and "해시" in g.get("error", "") and g.get("pct", 100) < 100, g)
    N.stop()
    M = Inst("noscript", fake="missing", install="ok", no_install_script=True)
    check("harness (no install script) starts", M.start())
    r = M.post("/llm/install")
    g = jb(M.get("/llm/install"))
    check("B1-11 no vendor install_tools.py -> error '설치 구성 요소 정보가 없어요', nothing started",
          jb(r).get("state") == "error" and g.get("state") == "error" and "설치 구성 요소 정보" in g.get("error", "") and not os.path.exists(M.install_runs), (jb(r), g))
    M.stop()

    # =========================================================================== B1-9 /health never blocks
    print("== B1-9 /health does not block on `opencode auth list`")
    D = Inst("slow", ctl={"auth_list_delay": 5})
    check("harness (slow auth list) starts", D.start(), D.server_log()[-300:])
    times = []
    for _ in range(8):
        t0 = time.perf_counter()
        r = D.get("/health")
        times.append(time.perf_counter() - t0)
        time.sleep(0.25)
    check("B1-9 GET /health answers within 1 s while `auth list` takes 5 s (max %.2f s)" % max(times), r.status_code == 200 and max(times) < 1.0, ["%.2f" % t for t in times])
    seen_state, t0 = "", time.time()
    while time.time() - t0 < 40:           # the slow answer arrives within about 5 s of the server start; under load it can take longer
        seen_state = jb(D.get("/health")).get("llm_state")
        if seen_state == "not_connected":
            break
        time.sleep(0.5)
    check("B1-9 once the slow answer is in, /health shows not_connected (polled, %.1f s)" % (time.time() - t0), seen_state == "not_connected", seen_state)
    D.stop()
    T = Inst("ttl", conn_ttl=1.0, logged_in=True)
    check("harness (short cache) starts", T.start())
    time.sleep(1.0)
    check("logged-in fake: llm_state ready", jb(T.get("/health")).get("llm_state") == "ready")
    T.write_ctl(auth_list_delay=5)
    time.sleep(1.3)
    t0 = time.perf_counter()
    r = T.get("/health")
    el = time.perf_counter() - t0
    check("B1-9 a stale cache is answered at once (%.2f s) and refreshed in the background" % el, r.status_code == 200 and el < 1.0 and jb(r).get("llm_state") == "ready", (el, jb(r)))
    T.stop()

    # =========================================================================== proxy
    print("== the key never goes to a proxy named by the environment")
    sink = ProxySink()
    P = Inst("proxy", proxy_port=sink.port)
    check("harness with HTTP_PROXY / HTTPS_PROXY / ALL_PROXY pointing at a fake proxy starts", P.start(), P.server_log()[-300:])
    r = P.post("/llm/connect", {"key": KEY4})
    check("connect works although the environment names a proxy (the local opencode is not reached through it)",
          r.status_code == 200 and jb(r).get("tested") is True, (r.status_code, jb(r)))
    check("the fake opencode got the key (so the PUT really went to it)", sha(KEY4) in [x.get("sha256") for x in P.received()])
    time.sleep(0.5)
    check("the fake proxy got 0 connections and never saw the key (connections: %d)" % sink.count, proxy_clean(sink, KEY4), sink.count)
    P.stop()
    sink.close()

    # =========================================================================== B1-5 leak scan
    print("== B1-5 marker key leak scan")
    for i in INSTS:
        if i.proc is not None:
            i.stop()
    hits = scan_leaks(WORK, patterns)
    bodies = [(u, s) for (u, s, t, h) in RESPONSES if any(p.decode("latin-1") in (t + h) for p in patterns)]
    cfgnow = hashlib.sha256(open(backend_cfg, "rb").read()).hexdigest() if os.path.isfile(backend_cfg) else ""
    leak = len(hits) + len(bodies) + (0 if cfgnow == cfg_hash0 else 1)
    print("SENTINEL_LEAK %d" % leak, flush=True)
    check("B1-5 SENTINEL_LEAK 0 (every file under the work folder, %d response bodies+headers, backend/config.json unchanged)" % len(RESPONSES), leak == 0, (hits[:5], bodies[:3]))
    check("B1-5 no secrets.json anywhere (work folder or backend/)", not any(n == "secrets.json" for _, _, fn in os.walk(WORK) for n in fn) and not os.path.exists(os.path.join(HERE, "secrets.json")))
    scanned = sum(len(fn) for _, _, fn in os.walk(WORK))
    check("B1-5 the scan looked at real files (server logs, fake state, opencode.log...)", scanned > 20 and os.path.exists(os.path.join(WORK, "main", "server.log")), scanned)
    log_text = open(os.path.join(WORK, "main", "server.log"), encoding="utf-8", errors="replace").read()
    check("B1-5 the server log has DEBUG output of the HTTP library and the connect lines (so a leak there would be visible)",
          "llm/connect ok" in log_text and "DEBUG" in log_text and "127.0.0.1" in log_text)

    # ---- the search must be able to FAIL: a harness that logs the key on purpose
    print("== B1-5 TEST OF THE TEST: deliberate log-the-key mutation must be found")
    X = Inst("mutant", mutate=True)
    check("mutant harness starts", X.start())
    KEYM = key_for("mutant")
    r = X.post("/llm/connect", {"key": KEYM})
    check("mutant connect still works (the leak is silent)", r.status_code == 200, r.status_code)
    X.stop()
    mut_hits = scan_leaks(X.dir, [b"SENTINEL", KEYM.encode()])
    print("SENTINEL_LEAK_MUTANT %d" % len(mut_hits), flush=True)
    check("B1-5 the leak search FAILS on the mutant (finds the key in its server log)", any(h[0].endswith("server.log") for h in mut_hits), mut_hits)
    probe = os.path.join(WORK, "probe_dir")
    os.makedirs(probe)
    open(os.path.join(probe, "a.txt"), "w").write("nothing here")
    ok_clean = scan_leaks(probe, [b"SENTINEL"]) == []
    open(os.path.join(probe, "b.txt"), "w").write("x SENTINEL-abc y")
    check("_Secret: logging the whole request dict shows <secret>, not the key (first line of the mutation)",
          "request body: {'type': 'api', 'key': <secret>}" in open(os.path.join(X.dir, "server.log"), encoding="utf-8", errors="replace").read())
    check("scan_leaks: clean folder -> 0 hits, folder with the marker -> hit", ok_clean and len(scan_leaks(probe, [b"SENTINEL"])) == 1)
    check("response check: a body holding the marker is detected", any(p.decode() in "oops " + KEY for p in patterns))

    print("== TEST OF THE TEST: trust_env=True must make the proxy check fail")
    sink2 = ProxySink()
    PM = Inst("proxymut", proxy_port=sink2.port, mutate_trust=True)
    check("proxy mutant harness starts", PM.start())
    PM.post("/llm/connect", {"key": KEY5}, timeout=120)
    time.sleep(0.8)
    check("the same proxy check FAILS on the mutant (proxy got %d connection(s), key seen: %s)" % (sink2.count, KEY5.encode() in sink2.data),
          not proxy_clean(sink2, KEY5) and sink2.count > 0 and KEY5.encode() in sink2.data)
    PM.stop()
    sink2.close()
    src_ll = open(os.path.join(HERE, "llm_opencode.py"), encoding="utf-8").read()
    check("source: llm_opencode.py sets _http.trust_env = False right after creating the session",
          re.search(r"_http = requests\.Session\(\)\n(#[^\n]*\n)*_http\.trust_env = False\n", src_ll) is not None)

    # =========================================================================== cleanup
    print("== cleanup")
    left = []
    for i in INSTS:
        if i.proc is not None and i.proc.poll() is None:
            kill_pid(i.pid)
    left = procs_under(WORK)
    for pid, _ in left:
        kill_pid(pid)
    mine = {i.pid for i in INSTS} | {pid for pid, _ in left}
    ns = subprocess.run(["netstat", "-ano", "-p", "tcp"], capture_output=True, creationflags=0x08000000).stdout.decode("utf-8", "replace")
    owners = {}
    for line in ns.splitlines():
        cols = line.split()
        if len(cols) >= 5 and cols[3] == "LISTENING" and cols[1].startswith("127.0.0.1:"):
            owners.setdefault(int(cols[1].rsplit(":", 1)[1]), int(cols[4]))
    ports_busy = [p for p in sorted(_EVER) if owners.get(p) in mine]
    others = {p: owners[p] for p in sorted(_EVER) if p in owners and owners[p] not in mine}
    if others:
        print("  [NOTE] port(s) %s are listened to by processes this test did not start (pid %s; 0 = the kernel is still closing it): another worker shares 18851-18859" % (
            sorted(others), sorted(set(others.values()))), flush=True)
    check("no process of this test left over and none of its ports still listened to by it (command line + netstat owner)", not left and not ports_busy,
          ([(p, c[:120]) for p, c in left], ports_busy))
    if not keep:
        shutil.rmtree(WORK, ignore_errors=True)
    n = len(results)
    ok = sum(1 for _, c in results if c)
    print(("LLM_CONNECT_TEST PASS %d/%d" % (ok, n)) if ok == n else ("LLM_CONNECT_TEST FAIL %d/%d" % (n - ok, n)), flush=True)
    _SUMMARY[0] = True
    for name, c in results:
        if not c:
            print("  FAILED: " + name)
    sys.exit(0 if ok == n else 1)


if __name__ == "__main__":
    main()
