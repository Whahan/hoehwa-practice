# -*- coding: utf-8 -*-
"""Phone link ("휴대폰 연결"): an extra listener on this PC's Tailscale address, pairing and device tokens. Contract: ../API.md "휴대폰 연결".

Design (docs/android_remote_design.md section 3; since 2026-10-17 the phone link is Tailscale only):
  * The normal 127.0.0.1 server is never touched or restarted. Turning the link on starts a SECOND uvicorn server (own thread, own event
    loop) on this PC's Tailscale IPv4 address(es) (100.64.0.0/10 on the adapter named "Tailscale"):<lan.port>, never on 0.0.0.0. Without a
    Tailscale address the link cannot be turned on (409 no_tailscale). Turning it off closes that port. If the Tailscale address
    disappears while the link is on, a watcher closes the listener and says why.
  * Only loopback and Tailscale sources (100.64.0.0/10, fd7a:115c:a1e0::/48) are served; a connection from anywhere else (private LAN,
    link-local, other ULA, public) is aborted before a byte is read. There is no UDP discovery: no UDP socket is opened.
  * Authentication is per LISTENER: every request that arrives through the link listener needs `Authorization: Bearer hp1_...`,
    even when its source IP is 127.0.0.1. The loopback listener keeps working without a token.
  * Only an allow-list of paths is served on the link listener; management endpoints (`/lan`, `/lan/code`, `/lan/devices/*`) are
    loopback only.
  * Only SHA-256 hashes of the tokens are stored (backend/lan_devices.json). Tokens, codes and Authorization headers are never logged.

server.py only calls `attach()`, `start_if_enabled()` and `shutdown()`; everything else lives here.
"""
import asyncio
import base64
import ctypes
import errno
import hashlib
import hmac
import ipaddress
import json
import logging
import math
import os
import re
import secrets
import socket
import struct
import subprocess
import threading
import time
from collections import deque
from datetime import datetime

from fastapi import APIRouter, Request
from fastapi.responses import JSONResponse
from starlette.concurrency import run_in_threadpool

router = APIRouter()

DEFAULT_LAN = {"enabled": False, "port": 8775, "name": ""}      # older config.json keys (discovery, allow_*) are ignored

CODE_TTL_SECONDS = 300
CODE_MAX_FAILS = 5
MAX_DEVICES = 8
BODY_LIMIT = 16 * 1024 * 1024          # bytes accepted from an authenticated LAN client
OPEN_BODY_LIMIT = 4096                 # bytes accepted before authentication (/pair, /lan/proof)
DRAIN_CAP = 32 * 1024 * 1024           # an upload we refuse is read (and thrown away) up to this much so the client sees our answer
RATE_FAILS = 30                        # bad tokens from one IP ...
RATE_WINDOW = 600.0                    # ... within this many seconds -> 429
FLUSH_SECONDS = 60.0                   # last_seen is written to disk at most this often
WATCH_SECONDS = 5.0                    # how often a running link checks that its Tailscale address still exists
DEVICES_FILE_MAX = 1024 * 1024
BAD_TOKEN_MAX_IPS = 2000               # rate-limit table size cap
PREAUTH_TIMEOUT = 10.0                 # seconds to receive a request before login (/pair, /lan/proof, rejected requests)
BODY_TIMEOUT = 120.0                   # seconds to receive an authenticated upload
HEADER_TIMEOUT = 10.0                  # seconds for the request line + headers to arrive completely (slowloris)
MAX_HEADER_BYTES = 16 * 1024           # request line + headers
HEADER_END = bytes([13, 10, 13, 10])   # CR LF CR LF
LOOPBACK_ONLY_NAMES = ("/lan", "/lan/code")

TOKEN_RE = re.compile(r"\A(?i:bearer)[ \t]+(hp1_[A-Za-z0-9_-]{43})\Z")
CODE_RE = re.compile(r"\A[0-9]{6}\Z")
NONCE_RE = re.compile(r"\A[0-9a-fA-F]{8,64}\Z")
HASH_RE = re.compile(r"\A[0-9a-f]{64}\Z")
ID_RE = re.compile(r"\A[0-9a-f]{8}\Z")
HOST_RE = re.compile(r"\A(127\.0\.0\.1|localhost|\[::1\])(:[0-9]{1,5})?\Z", re.I)
CTRL_RE = re.compile(r"[\x00-\x1f\x7f]")

# (method, path) that work without a token on the LAN listener
OPEN_PATHS = {("GET", "/hello"), ("POST", "/pair"), ("POST", "/lan/proof")}
# (method, path) a paired phone may call
ALLOW = {
    ("GET", "/health"), ("GET", "/curriculum"), ("POST", "/tts"), ("GET", "/tts/voices"), ("POST", "/stt"), ("POST", "/score"),
    ("POST", "/prosody"), ("POST", "/chat"), ("POST", "/feedback"), ("POST", "/fix"), ("POST", "/lesson"),
    ("POST", "/reading/analyze"), ("POST", "/reading/gloss"), ("GET", "/examples"), ("GET", "/lan/me"), ("POST", "/lan/unpair"),
    # English v1.1 practice and missions (practice.py, missions.py)
    ("GET", "/practice/ping"), ("GET", "/practice/sentences"), ("GET", "/practice/phonemes"), ("GET", "/practice/phoneme"),
    ("GET", "/missions"), ("POST", "/missions/check"), ("POST", "/missions/judge"),
    # 1.2 learning-record sync hub (sync_hub.py)
    ("GET", "/sync/pull"), ("POST", "/sync/push"),
}

MSG = {
    "code_format": "연결 코드는 숫자 6자리예요.",
    "token_missing": "이 PC에 연결되지 않았어요. 연결 코드를 입력해 주세요.",
    "token_invalid": "이 휴대폰의 연결이 해제됐어요. 다시 연결해 주세요.",
    "lan_forbidden": "휴대폰에서는 쓸 수 없는 기능이에요.",
    "local_only": "이 PC에서만 할 수 있어요.",
    "device_not_found": "연결된 기기를 찾지 못했어요.",
    "lan_off": "휴대폰 연결이 꺼져 있어요.",
    "device_limit": "연결할 수 있는 휴대폰이 가득 찼어요(최대 8대).",
    "no_active_code": "연결 코드가 없거나 시간이 지났어요. PC에서 새 코드를 만들어 주세요.",
    "too_large": "보낸 데이터가 너무 커요.",
    "pair_locked": "코드를 너무 많이 틀려서 잠겼어요. PC에서 새 코드를 만들어 주세요.",
    "rate_limited": "잠시 뒤에 다시 시도해 주세요.",
    "bad_request": "요청 형식이 올바르지 않아요.",
    "device_name_format": "이 휴대폰 이름은 1~40자로 입력해 주세요.",
    "store_failed": "연결 정보를 저장하지 못했어요. PC의 디스크 상태를 확인해 주세요.",
    "bad_origin": "허용되지 않은 요청이에요. 이 PC의 앱에서만 쓸 수 있어요.",
    "request_timeout": "요청을 받는 데 시간이 너무 오래 걸려요.",
    "no_tailscale": "이 PC에서 Tailscale이 꺼져 있거나 설치되지 않았어요. tailscale.com 에서 설치하고 휴대폰과 같은 구글 계정으로 로그인한 뒤 다시 켜 주세요.",
    "tailscale_lost": "이 PC의 Tailscale 연결이 사라져서 휴대폰 연결을 껐어요. Tailscale을 다시 켠 뒤 휴대폰 연결을 켜 주세요.",
}


# ----------------------------------------------------------------------------------------------
# small helpers
# ----------------------------------------------------------------------------------------------
def _now_iso():
    return datetime.now().astimezone().isoformat(timespec="seconds")


def _json_bytes(obj):
    return json.dumps(obj, ensure_ascii=False).encode("utf-8")


def _err(status, code, msg=None, **extra):
    body = {"error": msg or MSG.get(code, "요청을 처리할 수 없어요."), "code": code}
    body.update(extra)
    return JSONResponse(body, status_code=status)


def _is_loopback(host):
    try:
        ip = ipaddress.ip_address(host)
    except ValueError:
        return False
    if getattr(ip, "ipv4_mapped", None) is not None:
        ip = ip.ipv4_mapped
    return ip.is_loopback


_CGNAT = ipaddress.ip_network("100.64.0.0/10")           # Tailscale's IPv4 range
_TS_V6 = ipaddress.ip_network("fd7a:115c:a1e0::/48")      # Tailscale's IPv6 range


def _unmap(host):
    """text -> ipaddress object (an IPv4-mapped IPv6 address becomes the IPv4 one) | None when it is not an address"""
    try:
        ip = ipaddress.ip_address(host)
    except ValueError:
        return None
    if getattr(ip, "ipv4_mapped", None) is not None:
        ip = ip.ipv4_mapped
    return ip


def _source_allowed(host):
    """loopback and Tailscale only: IPv4 100.64.0.0/10, IPv6 fd7a:115c:a1e0::/48. Private LAN (10/8, 172.16/12, 192.168/16), link-local,
    any other ULA and the public internet get no answer at all."""
    ip = _unmap(host)
    if ip is None:
        return False
    if ip.is_loopback:
        return True
    if ip.version == 4:
        return ip in _CGNAT
    return ip in _TS_V6


def _peer_allowed(transport):
    try:
        peer = transport.get_extra_info("peername")
        return bool(peer) and _source_allowed(peer[0])
    except Exception:
        return False


TAILSCALE_MAX = 3
TAILSCALE_CACHE_SECONDS = 5.0


def _pick_tailscale(adapters):
    """adapters = [(friendly_name, description, is_up, [ip text, ...]), ...] -> up to 3 Tailscale IPv4 addresses (100.64.0.0/10).
    Only an adapter that is up AND has "tailscale" in its name or description counts: a carrier-CGNAT address on a normal
    adapter (Ethernet, Wi-Fi ...) is not ours to trust. IPv6 and non-CGNAT addresses of a Tailscale adapter are left out."""
    out = []
    for name, desc, up, ips in adapters:
        if not up or "tailscale" not in ("%s %s" % (name or "", desc or "")).lower():
            continue
        for text in ips or ():
            try:
                a = ipaddress.IPv4Address(text)
            except ValueError:
                continue
            if a in _CGNAT and str(a) not in out:
                out.append(str(a))
    return out[:TAILSCALE_MAX]


class _UnicastAddress(ctypes.Structure):
    pass


_UnicastAddress._fields_ = [("Length", ctypes.c_ulong), ("Flags", ctypes.c_ulong), ("Next", ctypes.POINTER(_UnicastAddress)),
                            ("lpSockaddr", ctypes.c_void_p), ("iSockaddrLength", ctypes.c_int)]


class _AdapterAddresses(ctypes.Structure):
    """IP_ADAPTER_ADDRESSES_LH up to OperStatus (the rest is never read)"""


_AdapterAddresses._fields_ = [("Length", ctypes.c_ulong), ("IfIndex", ctypes.c_ulong), ("Next", ctypes.POINTER(_AdapterAddresses)),
                              ("AdapterName", ctypes.c_char_p), ("FirstUnicastAddress", ctypes.POINTER(_UnicastAddress)),
                              ("FirstAnycastAddress", ctypes.c_void_p), ("FirstMulticastAddress", ctypes.c_void_p),
                              ("FirstDnsServerAddress", ctypes.c_void_p), ("DnsSuffix", ctypes.c_wchar_p),
                              ("Description", ctypes.c_wchar_p), ("FriendlyName", ctypes.c_wchar_p),
                              ("PhysicalAddress", ctypes.c_ubyte * 8), ("PhysicalAddressLength", ctypes.c_ulong),
                              ("Flags", ctypes.c_ulong), ("Mtu", ctypes.c_ulong), ("IfType", ctypes.c_ulong), ("OperStatus", ctypes.c_int)]


def _windows_adapters():
    """iphlpapi.GetAdaptersAddresses -> [(friendly_name, description, is_up, [ip text, ...]), ...]; [] on any failure"""
    try:
        if os.name != "nt":
            return []
        fn = ctypes.windll.iphlpapi.GetAdaptersAddresses
        fn.argtypes = [ctypes.c_ulong, ctypes.c_ulong, ctypes.c_void_p, ctypes.c_void_p, ctypes.POINTER(ctypes.c_ulong)]
        fn.restype = ctypes.c_ulong
        size = ctypes.c_ulong(16384)
        buf = None
        for _ in range(4):
            buf = ctypes.create_string_buffer(size.value)
            rc = fn(2, 0xE, None, buf, ctypes.byref(size))      # AF_INET; skip anycast / multicast / DNS server lists
            if rc == 0:
                break
            if rc != 111:                                       # ERROR_BUFFER_OVERFLOW: retry with the size it asked for
                return []
        else:
            return []
        out = []
        p = ctypes.cast(buf, ctypes.POINTER(_AdapterAddresses))
        n = 0
        while p and n < 512:
            a = p.contents
            ips = []
            u, m = a.FirstUnicastAddress, 0
            while u and m < 64:
                ua = u.contents
                if ua.lpSockaddr and 8 <= ua.iSockaddrLength <= 128:
                    raw = ctypes.string_at(ua.lpSockaddr, ua.iSockaddrLength)
                    fam = struct.unpack_from("<H", raw)[0]
                    if fam == 2:
                        ips.append(socket.inet_ntop(socket.AF_INET, raw[4:8]))
                    elif fam == 23 and len(raw) >= 24:
                        ips.append(socket.inet_ntop(socket.AF_INET6, raw[8:24]))
                u, m = ua.Next, m + 1
            out.append((a.FriendlyName or "", a.Description or "", a.OperStatus == 1, ips))
            p, n = a.Next, n + 1
        return out
    except Exception:
        return []


_ts_lock = threading.Lock()
_ts_cache = (float("-inf"), [])


def _fake_tailscale():
    """test hook: HOEHWA_TEST_HOOKS=1 and HOEHWA_LAN_ASSUME_TAILSCALE set -> the addresses to treat as this PC's Tailscale addresses
    (comma separated; only 100.64.0.0/10 and loopback 127.x are taken, so a test can bind on loopback; an empty value = "no Tailscale")
    | None (no hook: the real adapters decide)"""
    if os.environ.get("HOEHWA_TEST_HOOKS") != "1" or "HOEHWA_LAN_ASSUME_TAILSCALE" not in os.environ:
        return None
    out = []
    for part in os.environ["HOEHWA_LAN_ASSUME_TAILSCALE"].split(","):
        try:
            a = ipaddress.IPv4Address(part.strip())
        except ValueError:
            continue
        if (a in _CGNAT or a.is_loopback) and str(a) not in out:
            out.append(str(a))
    return out[:TAILSCALE_MAX]


def tailscale_addresses(fresh=False):
    """This PC's Tailscale IPv4 addresses (100.64.0.0/10 on an up adapter named / described "Tailscale"), at most 3. Never raises.
    The adapter list is cached for 5 seconds; fresh=True reads it again (turning the link on, the watcher)."""
    global _ts_cache
    fake = _fake_tailscale()
    if fake is not None:
        return fake
    with _ts_lock:
        now = time.monotonic()
        if not fresh and now - _ts_cache[0] < TAILSCALE_CACHE_SECONDS:
            return list(_ts_cache[1])
        try:
            found = _pick_tailscale(_windows_adapters())
        except Exception:
            found = []
        _ts_cache = (now, found)
        return list(found)


def _hook_seconds(name, default):
    if os.environ.get("HOEHWA_TEST_HOOKS") == "1" and os.environ.get(name):
        try:
            return min(600.0, max(0.5, float(os.environ[name])))
        except ValueError:
            pass
    return default


def _clean_name(value, limit=40):
    if not isinstance(value, str):
        return ""
    return CTRL_RE.sub("", value).strip()[:limit].strip()


def _code_ttl():
    ttl = float(CODE_TTL_SECONDS)
    if os.environ.get("HOEHWA_TEST_HOOKS") == "1" and os.environ.get("HOEHWA_LAN_CODE_TTL"):
        try:
            ttl = min(3600.0, max(0.5, float(os.environ["HOEHWA_LAN_CODE_TTL"])))
        except ValueError:
            pass
    return ttl


# ----------------------------------------------------------------------------------------------
# state
# ----------------------------------------------------------------------------------------------
class _State:
    def __init__(self):
        self.app = None
        self.cfg = {"lan": dict(DEFAULT_LAN)}
        self.save = None
        self.persist = False
        self.log = logging.getLogger("backend.lan")
        self.devices_path = ""
        self.devices = []
        self.dirty = False
        self.last_flush = 0.0
        self.lock = threading.RLock()        # guards devices / pairing / rate state
        self.op_lock = threading.Lock()      # one start/stop/reconfigure at a time
        self.listener = None
        self.bound = []                      # Tailscale addresses the running listener is bound to
        self.error = ""
        # pairing code
        self.code = None
        self.code_exp = 0.0
        self.fails = 0
        self.locked = False
        # bad-token rate limit: ip -> deque of monotonic times
        self.bad_tokens = {}

    @property
    def lan(self):
        return self.cfg["lan"]

    def name(self):
        n = _clean_name(self.lan.get("name"))
        if n:
            return n
        try:
            return _clean_name(socket.gethostname()) or "PC"
        except OSError:
            return "PC"


S = _State()


# ----------------------------------------------------------------------------------------------
# device store (SHA-256 of tokens only)
# ----------------------------------------------------------------------------------------------
def _valid_device(d):
    return (isinstance(d, dict) and isinstance(d.get("id"), str) and ID_RE.match(d["id"]) and isinstance(d.get("name"), str)
            and isinstance(d.get("token_sha256"), str) and HASH_RE.match(d["token_sha256"]))


def _load_devices():
    path = S.devices_path
    S.devices = []
    if not path or not os.path.exists(path):
        return
    try:
        if os.path.getsize(path) > DEVICES_FILE_MAX:
            raise ValueError("devices file too large")
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
        if not isinstance(data, dict) or not isinstance(data.get("devices"), list):
            raise ValueError("unexpected devices file shape")
        seen = set()
        for d in data["devices"]:
            if not _valid_device(d):
                S.log.warning("lan: skipped an invalid device entry")
                continue
            if d["id"] in seen:
                continue
            seen.add(d["id"])
            S.devices.append({"id": d["id"], "name": _clean_name(d["name"]) or "휴대폰", "token_sha256": d["token_sha256"],
                              "created": str(d.get("created") or ""), "last_seen": str(d.get("last_seen") or ""),
                              "last_ip": str(d.get("last_ip") or "")})
        S.devices = S.devices[:MAX_DEVICES]
    except Exception:
        # fail closed: old tokens stop working, the broken file is kept for inspection
        S.devices = []
        try:
            os.replace(path, path + ".bad")
            S.log.warning("lan: device file unreadable; moved to %s.bad, all phones must pair again", os.path.basename(path))
        except OSError:
            S.log.warning("lan: device file unreadable and could not be moved")


_SID = None


def _sys32(name):
    return os.path.join(os.environ.get("SystemRoot", r"C:\Windows"), "System32", name)


def _my_sid():
    """SID of the account this process runs as (whoami), or "" when unknown"""
    global _SID
    if _SID is None:
        _SID = ""
        try:
            r = subprocess.run([_sys32("whoami.exe"), "/user", "/fo", "csv", "/nh"], capture_output=True, text=True, timeout=5, creationflags=0x08000000)
            m = re.search(r"S-1-[0-9-]+", r.stdout or "")
            if r.returncode == 0 and m:
                _SID = m.group(0)
        except Exception:
            pass
    return _SID


def _owner_only(path):
    """best effort: only the account this process runs as may read the device file (token hashes). The grant uses the process SID,
    not the USERNAME variable, and is undone (ACL reset) if the file is not readable afterwards. Any doubt -> leave the default ACL."""
    if os.name != "nt":
        return
    sid = _my_sid()
    if not sid:
        return
    try:
        r = subprocess.run([_sys32("icacls.exe"), path, "/inheritance:r", "/grant:r", "*%s:(F)" % sid], capture_output=True, timeout=5, creationflags=0x08000000)
        ok = r.returncode == 0
        if ok:
            with open(path, "rb") as f:        # still ours?
                f.read(1)
            with open(path, "ab"):
                pass
    except Exception:
        ok = False
    if not ok:
        try:
            subprocess.run([_sys32("icacls.exe"), path, "/reset"], capture_output=True, timeout=5, creationflags=0x08000000)
        except Exception:
            pass


def _save_devices():
    """write the device file (caller holds S.lock). Raises OSError."""
    path = S.devices_path
    if not path:
        return
    out = {"version": 1, "devices": [{"id": d["id"], "name": d["name"], "token_sha256": d["token_sha256"], "created": d["created"],
                                      "last_seen": d["last_seen"], "last_ip": d["last_ip"]} for d in S.devices]}
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8", newline="\n") as f:
        json.dump(out, f, ensure_ascii=False, indent=2)
    _owner_only(tmp)
    os.replace(tmp, path)
    S.dirty = False
    S.last_flush = time.time()


def _flush_if_due(force=False):
    with S.lock:
        if S.dirty and (force or time.time() - S.last_flush >= FLUSH_SECONDS):
            try:
                _save_devices()
            except OSError:
                S.log.warning("lan: could not write the device file")
                S.last_flush = time.time()


def _public_device(d):
    return {"id": d["id"], "name": d["name"], "created": d["created"], "last_seen": d["last_seen"], "last_ip": d["last_ip"]}


def _find_by_token(token):
    h = hashlib.sha256(token.encode("ascii")).hexdigest()
    found = None
    with S.lock:
        for d in S.devices:      # no early exit: same work for hit and miss
            if hmac.compare_digest(d["token_sha256"], h):
                found = d
    return found


def _touch(dev, ip):
    with S.lock:
        dev["last_seen"] = _now_iso()
        dev["last_ip"] = ip
        S.dirty = True
    _flush_if_due()


# ----------------------------------------------------------------------------------------------
# pairing code
# ----------------------------------------------------------------------------------------------
def _new_code():
    with S.lock:
        S.code = "%06d" % secrets.randbelow(10 ** 6)
        S.code_exp = time.monotonic() + _code_ttl()
        S.fails = 0
        S.locked = False
        return S.code, int(math.ceil(_code_ttl()))


def _clear_code(reset_lock=True):
    with S.lock:
        S.code = None
        S.code_exp = 0.0
        S.fails = 0
        if reset_lock:
            S.locked = False


def _code_active():
    with S.lock:
        return S.code is not None and not S.locked and time.monotonic() < S.code_exp


def _pairing_view():
    with S.lock:
        active = _code_active()
        return {"active": active, "code": S.code if active else None,
                "expires_in": int(math.ceil(S.code_exp - time.monotonic())) if active else 0,
                "locked": S.locked, "attempts_left": 0 if S.locked else (max(0, CODE_MAX_FAILS - S.fails) if active else 0)}


# ----------------------------------------------------------------------------------------------
# rate limit for bad tokens
# ----------------------------------------------------------------------------------------------
def _rate_limited(ip):
    now = time.monotonic()
    with S.lock:
        q = S.bad_tokens.get(ip)
        if not q:
            return False
        while q and now - q[0] > RATE_WINDOW:
            q.popleft()
        if not q:
            S.bad_tokens.pop(ip, None)
            return False
        return len(q) >= RATE_FAILS


def _note_bad_token(ip):
    now = time.monotonic()
    with S.lock:
        if ip not in S.bad_tokens and len(S.bad_tokens) >= BAD_TOKEN_MAX_IPS:
            for k in [k for k, q in S.bad_tokens.items() if not q or now - q[-1] > RATE_WINDOW]:
                S.bad_tokens.pop(k, None)
            while len(S.bad_tokens) >= BAD_TOKEN_MAX_IPS:
                S.bad_tokens.pop(next(iter(S.bad_tokens)))     # oldest entry goes
        S.bad_tokens.setdefault(ip, deque(maxlen=RATE_FAILS * 2)).append(now)


# ----------------------------------------------------------------------------------------------
# LAN gate (ASGI)
# ----------------------------------------------------------------------------------------------
async def _send_json(send, status, obj, close=False):
    body = _json_bytes(obj)
    headers = [(b"content-type", b"application/json"), (b"content-length", str(len(body)).encode("ascii"))]
    if close:
        headers.append((b"connection", b"close"))
    await send({"type": "http.response.start", "status": status, "headers": headers})
    await send({"type": "http.response.body", "body": body})


def _gate_err(code, **extra):
    status = {"token_missing": 401, "token_invalid": 401, "lan_forbidden": 403, "local_only": 403, "too_large": 413,
              "rate_limited": 429, "request_timeout": 408}[code]
    body = {"error": MSG[code], "code": code}
    body.update(extra)
    return status, body


class _Slow(Exception):
    """the client took too long to send its request"""


async def _recv(receive, deadline):
    left = deadline - time.monotonic()
    if left <= 0:
        raise _Slow()
    try:
        return await asyncio.wait_for(receive(), left)
    except asyncio.TimeoutError:
        raise _Slow()


async def _drain(receive, deadline, already=0):
    """read (and throw away) the rest of the request body, up to DRAIN_CAP. -> True when the whole body was consumed.
    Answering before the client finished uploading makes Windows reset the connection and the client never sees the answer."""
    total = already
    while True:
        msg = await _recv(receive, deadline)
        if msg["type"] == "http.disconnect":
            return False
        total += len(msg.get("body", b"") or b"")
        if not msg.get("more_body"):
            return True
        if total > DRAIN_CAP:
            return False


async def _read_body(receive, limit, deadline):
    """-> (body bytes | None when over the limit, state) with state "ok" | "over" | "gone" (client disconnected) | "unread" (too big to drain)"""
    chunks, total = [], 0
    while True:
        msg = await _recv(receive, deadline)
        if msg["type"] == "http.disconnect":
            return None, "gone"
        part = msg.get("body", b"") or b""
        total += len(part)
        if total > limit:
            return None, ("over" if (not msg.get("more_body") or await _drain(receive, deadline, total)) else "unread")
        chunks.append(part)
        if not msg.get("more_body"):
            return b"".join(chunks), "ok"


def _make_protocol():
    """uvicorn's h11 protocol that drops a connection from a disallowed source address before reading a single byte"""
    from uvicorn.protocols.http.h11_impl import H11Protocol

    class LanH11Protocol(H11Protocol):
        _hdr_timer = None
        _hdr_buf = b""

        def connection_made(self, transport):
            if not _peer_allowed(transport):
                self.transport = transport     # connection_lost() expects it
                try:
                    transport.abort()
                except Exception:
                    pass
                return
            super().connection_made(transport)

        def _header_timeout(self):
            self._hdr_timer = None
            c = self.cycle
            if c is None or c.response_complete:       # still no complete request: drop the connection
                try:
                    self.transport.abort()
                except Exception:
                    pass

        def data_received(self, data):
            c0 = self.cycle
            if c0 is None or c0.response_complete:        # request line + headers of a new request are still arriving
                self._hdr_buf += data
                end = self._hdr_buf.find(HEADER_END)
                if (end if end >= 0 else len(self._hdr_buf)) > MAX_HEADER_BYTES:
                    try:
                        self.transport.abort()
                    except Exception:
                        pass
                    return
                if end >= 0:
                    self._hdr_buf = b""
            super().data_received(data)
            c = self.cycle
            if c is not None and not c.response_complete:      # headers are complete: the body limits take over
                if self._hdr_timer is not None:
                    self._hdr_timer.cancel()
                    self._hdr_timer = None
            elif self._hdr_timer is None and data:             # first bytes of a request that is not complete yet
                self._hdr_timer = self.loop.call_later(_hook_seconds("HOEHWA_LAN_HEADER_TIMEOUT", HEADER_TIMEOUT), self._header_timeout)

        def connection_lost(self, exc):
            if self._hdr_timer is not None:
                self._hdr_timer.cancel()
                self._hdr_timer = None
            super().connection_lost(exc)

    return LanH11Protocol


class LanGate:
    """Wraps the FastAPI app on the LAN listener only."""

    def __init__(self, app):
        self.app = app

    @staticmethod
    async def _reject(receive, send, code, declared, **extra):
        st, body = _gate_err(code, **extra)
        try:
            done = False if (declared is not None and declared > DRAIN_CAP) else await _drain(receive, time.monotonic() + _hook_seconds("HOEHWA_LAN_PREAUTH_TIMEOUT", PREAUTH_TIMEOUT))
        except _Slow:
            done = False
        await _send_json(send, st, body, close=not done)

    async def __call__(self, scope, receive, send):
        kind = scope["type"]
        if kind != "http":
            if kind == "websocket":
                try:
                    await send({"type": "websocket.close", "code": 1008})
                except Exception:
                    pass
            return
        ip = (scope.get("client") or ("?", 0))[0]
        if not _source_allowed(ip):
            return      # public / unknown source: no answer (the protocol class normally closed the connection already)
        scope["hoehwa_lan"] = True
        scope.pop("hoehwa_device", None)
        key = (scope.get("method", ""), scope.get("path", ""))
        declared = None
        for k, v in scope.get("headers", []):
            if k == b"content-length":
                try:
                    declared = int(v)
                except ValueError:
                    declared = None
                break
        if key not in OPEN_PATHS:
            if _rate_limited(ip):
                return await self._reject(receive, send, "rate_limited", declared)
            dev, why = self._auth(scope)
            if dev is None:
                if why == "token_invalid":
                    _note_bad_token(ip)
                return await self._reject(receive, send, why, declared)
            path = key[1]
            if path in LOOPBACK_ONLY_NAMES or path.startswith("/lan/devices"):
                return await self._reject(receive, send, "local_only", declared)
            if key not in ALLOW:
                return await self._reject(receive, send, "lan_forbidden", declared)
            scope["hoehwa_device"] = dev["id"]
            _touch(dev, ip)
        limit = OPEN_BODY_LIMIT if key in OPEN_PATHS else BODY_LIMIT
        if declared is not None and declared > limit:
            return await self._reject(receive, send, "too_large", declared)
        secs = _hook_seconds("HOEHWA_LAN_PREAUTH_TIMEOUT", PREAUTH_TIMEOUT) if key in OPEN_PATHS else _hook_seconds("HOEHWA_LAN_BODY_TIMEOUT", BODY_TIMEOUT)
        try:
            body_bytes, state = await _read_body(receive, limit, time.monotonic() + secs)
        except _Slow:
            st, body = _gate_err("request_timeout")
            return await _send_json(send, st, body, close=True)
        if state == "gone":
            return
        if body_bytes is None:
            st, body = _gate_err("too_large")
            return await _send_json(send, st, body, close=(state != "over"))
        sent = False

        async def replay():
            nonlocal sent
            if not sent:
                sent = True
                return {"type": "http.request", "body": body_bytes, "more_body": False}
            return await receive()

        await self.app(scope, replay, send)

    @staticmethod
    def _auth(scope):
        vals = [v for k, v in scope.get("headers", []) if k == b"authorization"]
        if not vals:
            return None, "token_missing"
        if len(vals) > 1:
            return None, "token_invalid"
        raw = vals[0].decode("latin-1").strip()
        if not raw:
            return None, "token_missing"
        m = TOKEN_RE.match(raw)
        if not m:
            return None, "token_invalid"
        dev = _find_by_token(m.group(1))
        if dev is None:
            return None, "token_invalid"
        return dev, ""


# ----------------------------------------------------------------------------------------------
# listeners
# ----------------------------------------------------------------------------------------------
def _bind_tcp(host, port):
    """one listening IPv4 socket on `host`:`port` (host is always one of this PC's Tailscale addresses, never 0.0.0.0)"""
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        sock.bind((host, port))
        sock.listen(128)
        sock.setblocking(False)
    except OSError:
        sock.close()
        raise
    return sock


class _Listener:
    """the second uvicorn server: own thread, own event loop, pre-bound sockets (one per Tailscale address)"""

    def __init__(self, addrs, port, socks):
        import uvicorn
        self.addrs = list(addrs)
        self.port = port
        self.socks = list(socks)
        cfg = uvicorn.Config(LanGate(S.app), lifespan="off", log_config=None, access_log=False, timeout_graceful_shutdown=2,
                             timeout_keep_alive=5, proxy_headers=False, server_header=False, interface="asgi3", http=_make_protocol(),
                             h11_max_incomplete_event_size=MAX_HEADER_BYTES)
        self.server = uvicorn.Server(cfg)
        self.done = threading.Event()
        self.watch_stop = threading.Event()
        self.crash = None
        self.thread = threading.Thread(target=self._main, name="lan-listener", daemon=True)

    def _main(self):
        try:
            self.server.run(sockets=self.socks)
        except BaseException as e:   # SystemExit from a failed startup included
            self.crash = repr(e)
            S.log.warning("lan: listener thread ended: %s", self.crash)
        finally:
            self.done.set()

    def start(self, timeout=8.0):
        self.thread.start()
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            if self.server.started:
                threading.Thread(target=_watch_loop, args=(self,), name="lan-watch", daemon=True).start()
                return
            if self.done.is_set():
                break
            time.sleep(0.02)
        self.stop()
        raise OSError("LAN listener did not start (%s)" % (self.crash or "timeout"))

    def alive(self):
        return self.thread.is_alive() and self.server.started and not self.done.is_set()

    def stop(self):
        self.watch_stop.set()
        self.server.should_exit = True
        if self.thread.is_alive():
            self.thread.join(5)
            if self.thread.is_alive():
                self.server.force_exit = True
                self.thread.join(3)
        for sock in self.socks:
            try:
                sock.close()
            except OSError:
                pass


def _watch_loop(ls):
    """while the link is on: if none of the addresses it listens on is a Tailscale address of this PC any more, close it"""
    while not ls.watch_stop.wait(_hook_seconds("HOEHWA_LAN_WATCH_SECONDS", WATCH_SECONDS)):
        try:
            if _watch_once(ls):
                return
        except Exception:
            S.log.warning("lan: watcher error", exc_info=True)


def _watch_once(ls):
    """-> True when the listener `ls` was closed because its Tailscale address is gone"""
    now = tailscale_addresses(fresh=True)
    if any(a in now for a in ls.addrs):
        return False
    with S.op_lock:
        if S.listener is not ls:
            return False
        _stop_all()
        S.lan["enabled"] = False       # not saved: the setting comes back at the next start when Tailscale is there again
        S.error = MSG["tailscale_lost"]
        S.log.warning("lan: Tailscale address %s is gone; link closed", ",".join(ls.addrs))
    return True


# ----------------------------------------------------------------------------------------------
# attach / start / stop / configure
# ----------------------------------------------------------------------------------------------
def attach(app, cfg, save_cfg, log, base_dir, tag=None, devices_file=None, persist=True, auto_start=True):
    """Connect to the host app. `cfg` is the server's whole config dict (cfg["lan"] is ours), `save_cfg(cfg)` persists it.
    auto_start=False (test servers): never start from the saved config, the link stays off until POST /lan says otherwise."""
    S.app = app
    S.cfg = cfg
    S.save = save_cfg
    S.persist = bool(persist)
    S.log = log
    lan = cfg.get("lan")
    merged = dict(DEFAULT_LAN)
    if isinstance(lan, dict):
        merged.update({k: v for k, v in lan.items() if k in DEFAULT_LAN})      # old keys (discovery, discovery_port, allow_*) are dropped
    v = merged.get("port")
    if type(v) is not int or not (1024 <= v <= 65535):
        merged["port"] = DEFAULT_LAN["port"]
    merged["enabled"] = merged.get("enabled") is True and bool(auto_start)
    merged["name"] = _clean_name(merged.get("name"))
    cfg["lan"] = merged
    if devices_file:
        S.devices_path = os.path.abspath(devices_file)
    else:
        S.devices_path = os.path.join(base_dir, "lan_devices-%s.json" % tag if tag else "lan_devices.json")
    _load_devices()
    app.include_router(router)


def _persist():
    if S.persist and S.save:
        try:
            S.save(S.cfg)
        except Exception:
            S.log.warning("lan: could not save config.json", exc_info=True)


def _start_listener(addrs, port):
    """bind one socket per Tailscale address first (OSError if one is busy / gone), then run the server; returns the _Listener"""
    socks = []
    try:
        for host in addrs:
            socks.append(_bind_tcp(host, port))
        ls = _Listener(addrs, port, socks)
        ls.start()
    except OSError:
        for sock in socks:
            try:
                sock.close()
            except OSError:
                pass
        raise
    S.bound = list(addrs)
    return ls


def _bind_failure(exc):
    """OSError from _start_listener -> "no_tailscale" (the address is not on this PC any more) | "lan_port_busy" """
    if getattr(exc, "errno", None) in (errno.EADDRNOTAVAIL, 10049):
        return "no_tailscale"
    return "lan_port_busy"


def start_if_enabled():
    """lifespan start: bring the link up when the saved config says so (no Tailscale address / a busy port turns it off again)"""
    with S.op_lock:
        lan = S.lan
        if not lan["enabled"] or S.listener is not None:
            return
        addrs = tailscale_addresses(fresh=True)
        if not addrs:
            lan["enabled"] = False      # not saved: the setting comes back when Tailscale is running again
            S.error = MSG["no_tailscale"]
            S.log.warning("lan: no Tailscale address at start; link stays off")
            return
        try:
            S.listener = _start_listener(addrs, lan["port"])
        except OSError as e:
            lan["enabled"] = False
            if _bind_failure(e) == "no_tailscale":
                S.error = MSG["no_tailscale"]
            else:
                S.error = "포트 %d를 다른 프로그램이 쓰고 있어서 휴대폰 연결을 켜지 못했어요." % lan["port"]
                _persist()
            S.log.warning("lan: could not listen on %s:%d at start; link stays off", ",".join(addrs), lan["port"])
            return
        _new_code()
        S.log.info("lan: listening on %s:%d", ",".join(addrs), lan["port"])


def shutdown():
    """lifespan end: close the port and flush the device file. The saved 'enabled' stays as it was."""
    with S.op_lock:
        if S.listener is not None:
            S.listener.stop()
            S.listener = None
        S.bound = []
        _clear_code()
    _flush_if_due(force=True)


def _stop_all():
    if S.listener is not None:
        S.listener.stop()
        S.listener = None
    S.bound = []
    _clear_code()


def _configure(upd):
    """apply a validated update. -> (None, None) ok | (status, code) failure with nothing changed"""
    with S.op_lock:
        lan = S.lan
        new = dict(lan)
        new.update(upd)
        S.error = ""
        was_on = S.listener is not None
        if new["enabled"]:
            if was_on and S.listener.port == new["port"] and not S.listener.alive():
                S.listener.stop()      # a crashed listener may still hold the port: free it before binding again
                S.listener = None
                was_on = False
            if (not was_on) or S.listener.port != new["port"]:
                addrs = tailscale_addresses(fresh=True)        # looked up again every time the link is turned on
                if not addrs:
                    if not was_on:
                        lan["enabled"] = False
                    return 409, "no_tailscale"
                try:
                    fresh = _start_listener(addrs, new["port"])
                except OSError as e:
                    if not was_on:
                        lan["enabled"] = False
                    return 409, _bind_failure(e)
                old, S.listener = S.listener, fresh
                if old is not None:
                    old.stop()
            lan.update(new)
            if not was_on:
                _new_code()
        else:
            _stop_all()
            lan.update(new)
        _persist()
    return None, None


def _status():
    lan = S.lan
    with S.lock:
        devices = [_public_device(d) for d in S.devices]
    ts = tailscale_addresses()
    listening = bool(S.listener is not None and S.listener.alive())
    return {"network_safe": bool(ts), "network_reason": "" if ts else MSG["no_tailscale"], "tailscale_addresses": ts,
            "enabled": bool(lan["enabled"]), "listening": listening, "port": lan["port"], "bind": list(S.bound) if listening else [],
            "name": S.name(), "pairing": _pairing_view(), "devices": devices, "error": S.error}


# ----------------------------------------------------------------------------------------------
# endpoints
# ----------------------------------------------------------------------------------------------
async def _json_body(request, allow_empty=False):
    """-> dict | None (not a JSON object)"""
    raw = await request.body()
    if not raw.strip():
        return {} if allow_empty else None
    try:
        data = json.loads(raw.decode("utf-8"))
    except (ValueError, UnicodeDecodeError):
        return None
    return data if isinstance(data, dict) else None


def _local_only(request):
    if request.scope.get("hoehwa_lan"):
        return _err(403, "local_only")
    host = request.client.host if request.client else ""
    if not _is_loopback(host):
        return _err(403, "local_only")
    # a web page in the user's browser must not be able to drive these endpoints (CSRF, DNS rebinding)
    hv = request.headers.get("host", "")
    if not HOST_RE.match(hv):
        return _err(403, "bad_origin")
    origin = request.headers.get("origin")
    if origin is not None and origin.lower() != ("http://" + hv).lower():
        return _err(403, "bad_origin")
    if request.method == "POST" and request.headers.get("content-type", "").split(";")[0].strip().lower() != "application/json":
        return _err(403, "bad_origin")
    return None


@router.get("/hello")
def hello():
    return {"hoehwa": 1, "name": S.name(), "pairing_open": _code_active()}


@router.post("/pair")
async def pair(request: Request):
    data = await _json_body(request)
    if data is None:
        return _err(400, "bad_request")
    code, name = data.get("code"), data.get("device_name")
    if not isinstance(code, str) or not CODE_RE.match(code):
        return _err(400, "code_format")
    name = _clean_name(name)
    if not name:
        return _err(400, "device_name_format")
    ip = request.client.host if request.client else ""
    with S.lock:
        if S.locked:
            return _err(429, "pair_locked", attempts_left=0)
        if not _code_active():
            return _err(410, "no_active_code")
        if not hmac.compare_digest(code.encode("ascii"), S.code.encode("ascii")):
            S.fails += 1
            left = max(0, CODE_MAX_FAILS - S.fails)
            if S.fails >= CODE_MAX_FAILS:
                S.code, S.code_exp, S.locked = None, 0.0, True
                S.log.warning("lan: pairing locked after %d wrong codes (from %s)", CODE_MAX_FAILS, ip)
                return _err(401, "code_invalid", "코드가 맞지 않아요. 남은 기회가 없어요. PC에서 새 코드를 만들어 주세요.", attempts_left=0)
            return _err(401, "code_invalid", "코드가 맞지 않아요. 남은 기회 %d번." % left, attempts_left=left)
        if len(S.devices) >= MAX_DEVICES:
            return _err(409, "device_limit")
        token = "hp1_" + base64.urlsafe_b64encode(secrets.token_bytes(32)).rstrip(b"=").decode("ascii")
        ids = {d["id"] for d in S.devices}
        dev_id = secrets.token_hex(4)
        while dev_id in ids:
            dev_id = secrets.token_hex(4)
        now = _now_iso()
        dev = {"id": dev_id, "name": name, "token_sha256": hashlib.sha256(token.encode("ascii")).hexdigest(), "created": now,
               "last_seen": now, "last_ip": ip}
        S.devices.append(dev)
        try:
            _save_devices()
        except OSError:
            S.devices.remove(dev)
            S.log.warning("lan: could not write the device file; pairing cancelled")
            return _err(500, "store_failed")
        S.code, S.code_exp, S.fails = None, 0.0, 0     # single use
        S.bad_tokens.pop(ip, None)                     # a successful pairing clears this address's bad-token record (else the new token gets 429 for up to RATE_WINDOW)
        S.log.info("lan: paired device %s (%s) from %s", dev_id, name, ip)
    return {"token": token, "device_id": dev_id, "server_name": S.name(), "port": int(S.lan["port"])}


@router.post("/lan/proof")
async def proof(request: Request):
    data = await _json_body(request)
    if data is None:
        return _err(400, "bad_request")
    dev_id, nonce = data.get("device_id"), data.get("nonce")
    if not isinstance(dev_id, str) or not isinstance(nonce, str) or not NONCE_RE.match(nonce):
        return _err(400, "bad_request")
    ip = request.client.host if request.client else ""
    if _rate_limited(ip):
        return _err(429, "rate_limited")
    with S.lock:
        dev = next((d for d in S.devices if d["id"] == dev_id), None)
        key_hex = dev["token_sha256"] if dev else ""
    if dev is None:
        _note_bad_token(ip)       # guessing device ids counts like guessing tokens
        return _err(404, "device_not_found")
    mac = hmac.new(bytes.fromhex(key_hex), nonce.encode("utf-8"), hashlib.sha256).hexdigest()
    return {"proof": mac}


def _device_of(request):
    dev_id = request.scope.get("hoehwa_device")
    if not dev_id:
        return None
    with S.lock:
        return next((d for d in S.devices if d["id"] == dev_id), None)


@router.get("/lan/me")
def lan_me(request: Request):
    dev = _device_of(request)
    if dev is None:
        return _err(404, "device_not_found")
    return {"device_id": dev["id"], "name": dev["name"], "server_name": S.name()}


@router.post("/lan/unpair")
def lan_unpair(request: Request):
    dev = _device_of(request)
    if dev is None:
        return _err(404, "device_not_found")
    with S.lock:
        S.devices = [d for d in S.devices if d["id"] != dev["id"]]
        try:
            _save_devices()
        except OSError:
            S.log.warning("lan: could not write the device file")
    S.log.info("lan: device %s unpaired itself", dev["id"])
    return {"ok": True}


@router.get("/lan")
def lan_get(request: Request):
    bad = _local_only(request)
    if bad is not None:
        return bad
    return _status()


def _parse_update(data):
    """validated POST /lan body -> update dict | None (400). Other keys (the old discovery, discovery_port, allow_cgnat, allow_tailscale)
    are ignored."""
    upd = {}
    if "enabled" in data:
        if type(data["enabled"]) is not bool:
            return None
        upd["enabled"] = data["enabled"]
    if "port" in data:
        v = data["port"]
        if type(v) is not int or not (1024 <= v <= 65535):
            return None
        upd["port"] = v
    if "name" in data:
        if not isinstance(data["name"], str) or len(data["name"]) > 80:
            return None
        upd["name"] = _clean_name(data["name"])
    return upd


@router.post("/lan")
async def lan_set(request: Request):
    bad = _local_only(request)
    if bad is not None:
        return bad
    data = await _json_body(request, allow_empty=True)
    upd = _parse_update(data) if data is not None else None
    if upd is None:
        return _err(400, "bad_request")
    status, code = await run_in_threadpool(_configure, upd)
    if status:
        if code == "no_tailscale":
            return _err(status, code)
        port = upd.get("port", S.lan["port"])
        return _err(status, code, "포트 %d을(를) 다른 프로그램이 쓰고 있어요." % port)
    return await run_in_threadpool(_status)


@router.post("/lan/code")
async def lan_code(request: Request):
    bad = _local_only(request)
    if bad is not None:
        return bad
    data = await _json_body(request, allow_empty=True)
    if data is None:
        return _err(400, "bad_request")
    if not S.lan["enabled"] or S.listener is None:
        return _err(409, "lan_off")
    if data.get("cancel") is True:
        _clear_code()
        return {"ok": True}
    code, ttl = _new_code()
    return {"code": code, "expires_in": ttl}


@router.post("/lan/devices/revoke")
async def lan_revoke(request: Request):
    bad = _local_only(request)
    if bad is not None:
        return bad
    data = await _json_body(request)
    if data is None:
        return _err(400, "bad_request")
    with S.lock:
        if data.get("all") is True:
            n = len(S.devices)
            S.devices = []
        else:
            dev_id = data.get("id")
            if not isinstance(dev_id, str):
                return _err(400, "bad_request")
            keep = [d for d in S.devices if d["id"] != dev_id]
            n = len(S.devices) - len(keep)
            if n == 0:
                return _err(404, "device_not_found")
            S.devices = keep
        try:
            _save_devices()
        except OSError:
            S.log.warning("lan: could not write the device file")
    S.log.info("lan: revoked %d device(s)", n)
    return {"ok": True, "revoked": n}
