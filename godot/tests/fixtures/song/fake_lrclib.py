# -*- coding: utf-8 -*-
"""Fake LRCLIB server for tests (task K6; used by G3 LrclibClient test, U2, E1). CC0, hand-written.

Mimics the parts of https://lrclib.net/docs that the app uses, with made-up songs (the lyrics are the hand-written
test lines in lyrics_en.txt / lyrics_ja.txt; times come from song_en.truth.json / song_ja.truth.json if present).
Never contacts the internet; binds 127.0.0.1 only (any other --host is refused).

  python -I fake_lrclib.py [--port 18797]          (prints "FAKE_LRCLIB_READY 127.0.0.1:<port>" when listening)

API (all JSON, UTF-8):
  GET  /api/get?track_name=&artist_name=[&album_name=][&duration=]   200 one record | 404 TrackNotFound
         (case-insensitive name match; when duration is given it must be within +-2 s, like the real service)
  GET  /api/get-cached?...                                             same as /api/get
  GET  /api/get/{id}                                                   200 record | 404
  GET  /api/search?q=...  or  ?track_name=...[&artist_name=...]        200 [record, ...] (empty list when nothing)
  record = {id, name, trackName, artistName, albumName, duration, instrumental, plainLyrics, syncedLyrics}
           (plainLyrics / syncedLyrics are null when absent; syncedLyrics is LRC "[mm:ss.xx] text")
  any other /api/... path (publish, flag, request-challenge ...)       405/404 and it is counted in /_log "bad_calls"

Songs: "Kettle Morning" / "Test Artist" (en, 21 s, synced), same name 10 s longer (another version), "Kettle Morning"
  by "Offset Artist" (all times +1.2 s), "Plain Boat" (plain lyrics only), "Quiet Room" (instrumental),
  "Kettle Morning (Live)", ja "やかんの朝" / "テスト歌手", and q=many -> 25 results.

Scenarios (put the word in track_name, artist_name or q; any request also accepts ?_delay=<ms>, max 10000):
  __429__        always 429, header Retry-After: 1        __429_once__  first call 429 (Retry-After: 1), later calls normal
  __429_nohdr__  429 without Retry-After                   __500__       500 with a JSON error body
  __badjson__    200 with truncated JSON                   __html__      200 with an HTML page (content-type text/html)
  __drop__       connection closed without a response     __empty__     /api/get -> 404, /api/search -> []
  __slow__       answers after 1.5 s

Control / inspection (not logged):
  GET  /_ping    -> "ok"
  GET  /_log     -> {"requests": [{"n","t","method","path","query","headers":{user-agent, lrclib-client, x-user-agent}}],
                     "bad_calls": [...]}   t = seconds since server start (monotonic), for spacing checks
  POST /_reset   -> clears the log and the __429_once__ counters
  POST /_quit    -> stops the server
Every /api answer also carries X-Echo-User-Agent and X-Echo-Lrclib-Client response headers (what the client sent).
"""
import argparse
import json
import os
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, unquote, urlparse

HERE = os.path.dirname(os.path.abspath(__file__))
T0 = time.monotonic()
LOCK = threading.Lock()
LOG = []
BAD_CALLS = []
ONCE = {}


def load_lines(lang, fallback_texts):
    """-> (list of (t0, text), duration). Times from the truth file when it exists."""
    p = os.path.join(HERE, "song_%s.truth.json" % lang)
    try:
        with open(p, "r", encoding="utf-8") as f:
            tr = json.load(f)
        return [(float(l["t0"]), l["text"]) for l in tr["lines"]], float(tr["duration"])
    except Exception:
        return [(2.0 + 3.5 * i, t) for i, t in enumerate(fallback_texts)], 2.0 + 3.5 * len(fallback_texts) + 1.5


def lyric_texts(lang):
    out = []
    try:
        with open(os.path.join(HERE, "lyrics_%s.txt" % lang), "r", encoding="utf-8") as f:
            for raw in f.read().splitlines():
                s = raw.strip()
                if s and not s.startswith("#"):
                    out.append(s)
    except Exception:
        pass
    return out or ["la la la"]


def lrc(lines, shift=0.0):
    out = []
    for t, text in lines:
        t = max(0.0, t + shift)
        out.append("[%02d:%05.2f] %s" % (int(t // 60), t - 60 * int(t // 60), text))
    return "\n".join(out)


def build_db():
    en_lines, en_dur = load_lines("en", lyric_texts("en"))
    ja_lines, ja_dur = load_lines("ja", lyric_texts("ja"))
    en_plain = "\n".join(t for _, t in en_lines)
    ja_plain = "\n".join(t for _, t in ja_lines)

    def rec(i, name, artist, album, dur, plain, synced, instrumental=False):
        return {"id": i, "name": name, "trackName": name, "artistName": artist, "albumName": album,
                "duration": float(dur), "instrumental": instrumental, "plainLyrics": plain, "syncedLyrics": synced}

    d = round(en_dur)
    db = [
        rec(1001, "Kettle Morning", "Test Artist", "Fixtures", d, en_plain, lrc(en_lines)),
        rec(1002, "Kettle Morning", "Test Artist", "Fixtures (Long Edit)", d + 10, en_plain, lrc(en_lines)),
        rec(1003, "Plain Boat", "Test Artist", "Fixtures", 30, en_plain, None),
        rec(1004, "Quiet Room", "Test Artist", "Fixtures", 45, None, None, instrumental=True),
        rec(1005, "Kettle Morning (Live)", "Test Artist", "Fixtures Live", d + 3, en_plain, lrc(en_lines)),
        rec(1006, "Kettle Morning", "Offset Artist", "Fixtures", d, en_plain, lrc(en_lines, 1.2)),
        rec(2001, "やかんの朝", "テスト歌手", "テスト", round(ja_dur), ja_plain, lrc(ja_lines)),
    ]
    for n in range(25):
        db.append(rec(3000 + n, "Many Songs %02d" % n, "Crowd Artist", "Crowd", 100 + n, "one\ntwo", "[00:01.00] one\n[00:02.00] two"))
    return db


DB = build_db()


def match_get(q):
    name = (q.get("track_name") or [""])[0].strip().lower()
    artist = (q.get("artist_name") or [""])[0].strip().lower()
    dur = (q.get("duration") or [""])[0].strip()
    for r in DB:
        if r["trackName"].lower() != name or r["artistName"].lower() != artist:
            continue
        if dur:
            try:
                if abs(float(dur) - r["duration"]) > 2.0:
                    continue
            except ValueError:
                return None
        return r
    return None


def match_search(q):
    qq = (q.get("q") or [""])[0].strip().lower()
    name = (q.get("track_name") or [""])[0].strip().lower()
    artist = (q.get("artist_name") or [""])[0].strip().lower()
    if qq == "many":
        return [r for r in DB if r["artistName"] == "Crowd Artist"]
    out = []
    for r in DB:
        hay = (r["trackName"] + " " + r["artistName"]).lower()
        if qq and qq not in hay:
            continue
        if name and name not in r["trackName"].lower():
            continue
        if artist and artist not in r["artistName"].lower():
            continue
        if qq or name or artist:
            out.append(r)
    return out


class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "FakeLRCLIB/1"

    def log_message(self, fmt, *a):
        pass

    # --- helpers
    def _send(self, code, body, ctype="application/json; charset=utf-8", extra=None):
        data = body if isinstance(body, bytes) else json.dumps(body, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Connection", "close")
        h = self.headers
        self.send_header("X-Echo-User-Agent", (h.get("User-Agent") or "").encode("ascii", "replace").decode("ascii"))
        self.send_header("X-Echo-Lrclib-Client", (h.get("Lrclib-Client") or "").encode("ascii", "replace").decode("ascii"))
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(data)
        self.close_connection = True

    def _err(self, code, name, msg, extra=None):
        self._send(code, {"code": code, "name": name, "message": msg}, extra=extra)

    def _record(self, parsed):
        with LOCK:
            n = len(LOG) + 1
            LOG.append({"n": n, "t": round(time.monotonic() - T0, 3), "method": self.command, "path": parsed.path,
                        "query": {k: v[0] for k, v in parse_qs(parsed.query).items()},
                        "headers": {"user-agent": self.headers.get("User-Agent", ""),
                                    "lrclib-client": self.headers.get("Lrclib-Client", ""),
                                    "x-user-agent": self.headers.get("X-User-Agent", "")}})

    def _scenario(self, q):
        text = " ".join(" ".join(q.get(k, [])) for k in ("track_name", "artist_name", "q")).lower()
        for w in ("__429_once__", "__429_nohdr__", "__429__", "__500__", "__badjson__", "__html__", "__drop__", "__empty__", "__slow__"):
            if w in text:
                return w
        return ""

    # --- routing
    def do_GET(self):
        self._handle("GET")

    def do_POST(self):
        self._handle("POST")

    def do_PUT(self):
        self._handle("PUT")

    def do_DELETE(self):
        self._handle("DELETE")

    def _handle(self, method):
        parsed = urlparse(self.path)
        path = parsed.path
        q = parse_qs(parsed.query)
        if method == "POST":
            ln = int(self.headers.get("Content-Length") or 0)
            if ln:
                self.rfile.read(ln)
        if path.startswith("/_"):
            return self._control(method, path)
        if not path.startswith("/api/"):
            return self._err(404, "NotFound", "unknown path")
        self._record(parsed)
        if method != "GET" or path.rstrip("/") not in ("/api/get", "/api/get-cached", "/api/search") and not path.startswith("/api/get/"):
            with LOCK:
                BAD_CALLS.append({"method": method, "path": path})
            return self._err(405 if method != "GET" else 404, "NotAllowed", "not available in the fake server")
        try:
            delay = min(10000, int((q.get("_delay") or ["0"])[0]))
        except ValueError:
            delay = 0
        sc = self._scenario(q)
        if sc == "__slow__":
            delay = max(delay, 1500)
        if delay:
            time.sleep(delay / 1000.0)
        if sc == "__drop__":
            self.close_connection = True
            try:
                self.connection.shutdown(2)
            except Exception:
                pass
            self.connection.close()
            return
        if sc == "__429__":
            return self._err(429, "RateLimited", "Too many requests", {"Retry-After": "1"})
        if sc == "__429_nohdr__":
            return self._err(429, "RateLimited", "Too many requests")
        if sc == "__429_once__":
            with LOCK:
                first = not ONCE.get(path)
                ONCE[path] = True
            if first:
                return self._err(429, "RateLimited", "Too many requests", {"Retry-After": "1"})
            q = dict(q)
            q["track_name"], q["artist_name"], q["q"] = ["Kettle Morning"], ["Test Artist"], ["Kettle Morning"]
        if sc == "__500__":
            return self._err(500, "InternalError", "Something broke")
        if sc == "__badjson__":
            return self._send(200, b'{"id": 1001, "trackName": "Kettle Mor')
        if sc == "__html__":
            return self._send(200, b"<html><body>captive portal</body></html>", "text/html; charset=utf-8")
        p = path.rstrip("/")
        if p == "/api/search":
            return self._send(200, [] if sc == "__empty__" else match_search(q))
        if path.startswith("/api/get/"):
            try:
                i = int(unquote(path.rsplit("/", 1)[1]))
            except ValueError:
                return self._err(400, "ValidationError", "bad id")
            for r in DB:
                if r["id"] == i:
                    return self._send(200, r)
            return self._err(404, "TrackNotFound", "Failed to find specified track")
        # /api/get, /api/get-cached
        if not (q.get("track_name") or [""])[0].strip() or not (q.get("artist_name") or [""])[0].strip():
            return self._err(400, "ValidationError", "track_name and artist_name are required")
        r = None if sc == "__empty__" else match_get(q)
        if r is None:
            return self._err(404, "TrackNotFound", "Failed to find specified track")
        self._send(200, r)

    def _control(self, method, path):
        if path == "/_ping":
            return self._send(200, b"ok", "text/plain")
        if path == "/_log":
            with LOCK:
                return self._send(200, {"requests": list(LOG), "bad_calls": list(BAD_CALLS)})
        if path == "/_reset" and method == "POST":
            with LOCK:
                del LOG[:]
                del BAD_CALLS[:]
                ONCE.clear()
            return self._send(200, {"ok": True})
        if path == "/_quit" and method == "POST":
            self._send(200, {"ok": True})
            threading.Thread(target=self.server.shutdown, daemon=True).start()
            return
        self._err(404, "NotFound", "unknown control path")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=18797)
    ap.add_argument("--host", default="127.0.0.1")
    a = ap.parse_args()
    if a.host not in ("127.0.0.1", "localhost", "::1"):
        print("refusing to bind %s: the fake server is local only / 로컬 전용이라 이 주소에는 열지 않아요" % a.host, file=sys.stderr)
        return 2
    try:
        srv = ThreadingHTTPServer((a.host, a.port), H)
    except OSError as e:
        print("cannot listen on %s:%d (%s) / 포트를 열 수 없어요" % (a.host, a.port, e), file=sys.stderr)
        return 1
    srv.daemon_threads = True
    print("FAKE_LRCLIB_READY %s:%d" % (a.host, a.port), flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    srv.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
