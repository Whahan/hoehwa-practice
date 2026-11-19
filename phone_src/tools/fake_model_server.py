#!/usr/bin/env python3
"""Fake model server for the ModelStore tests (docs/v201_design.md 2.2, 5.3 PA3-1..PA3-11).

Usage:   python -I -X utf8 fake_model_server.py --port 18791 --root <dir> [--ttl 900]
         (--port 0 lets the OS choose the port; the chosen port is written to <root>/port.txt)

It listens on 127.0.0.1 only, serves payload files from <root> and appends one JSON line per request to
<root>/requests.jsonl. Nothing here talks to the network. The Godot test writes the payload files itself and
reads the log file (the test code has no HTTP client of its own).

Request path:   /f/<token>/<payload file name>?<behaviour switches>
  token         free text that groups the requests of one test case in the log
  switches      (all optional, combined freely)
    redir=N       answer N times with a redirect before serving (each hop lowers N)
    code=302      redirect status (301 302 303 307 308)
    kind=abs|rel|sig|evil|suffix|plainhttp
                  abs   Location is http://127.0.0.1:<port>/...   (default)
                  rel   Location is a path starting with /
                  sig   like abs, with a signed-looking ?sig=... query (must never be stored by the app)
                  evil  Location is https://evilgithub.com/...        (the app must refuse)
                  suffix Location is https://release-assets.githubusercontent.com/...  (allowed by suffix)
                  plainhttp Location is http://github.com/...         (http: the app must refuse)
    cut=P         the first answer that would serve the body sends P percent of it and drops the connection
    norange=1     ignore a Range header and send 200 with the whole body
    r416=1        answer 416 when a Range header is present
    slow=MS       sleep MS milliseconds after every 64 KB chunk
    status=NNN    answer that status with a short body, always
    zero=1        200 with an empty body
    clmis=D       declare (and send) D bytes less/more than the file really has (Content-Length mismatch)
    over=D        send D extra bytes after the file (Content-Length says file size + D)
    stall=K       send K KB, then say nothing for 8 seconds (a dead connection)
    nocl=1        send no Content-Length at all (the body ends when the connection closes)
"""
import argparse
import json
import os
import re
import socket
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit, urlencode

CHUNK = 65536
STATE_LOCK = threading.Lock()
FIRST_DONE = set()   # tokens whose cut-off already happened
SEQ = [0]
ARGS = None


def log_line(rec):
    with STATE_LOCK:
        SEQ[0] += 1
        rec["seq"] = SEQ[0]
        with open(os.path.join(ARGS.root, "requests.jsonl"), "a", encoding="utf-8") as f:
            f.write(json.dumps(rec, ensure_ascii=False) + "\n")


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "FakeModel/1"

    def log_message(self, *a):  # silence the default stderr log
        pass

    def _send(self, code, body=b"", headers=None):
        self.send_response(code)
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        if body:
            self.wfile.write(body)
        self.close_connection = True

    def do_GET(self):
        sp = urlsplit(self.path)
        if sp.path == "/_ping":
            self._send(200, b"ok")
            return
        q = {k: v[0] for k, v in parse_qs(sp.query, keep_blank_values=True).items()}
        m = re.match(r"^/f/([^/]+)/([^/]+)$", sp.path)
        rng = self.headers.get("Range")
        rec = {"token": m.group(1) if m else "", "path": sp.path, "range": rng or "", "sent": 0,
               "status": 0, "host": self.headers.get("Host", ""), "redir": q.get("redir", "")}
        if not m:
            rec["status"] = 404
            log_line(rec)
            self._send(404, b"no")
            return
        token, name = m.group(1), m.group(2)
        payload_path = os.path.join(ARGS.root, os.path.basename(name))
        redir = int(q.get("redir", "0") or 0)
        port = self.server.server_address[1]
        if redir > 0:
            code = int(q.get("code", "302") or 302)
            kind = q.get("kind", "abs")
            q2 = dict(q)
            q2["redir"] = str(redir - 1)
            if kind == "sig":
                q2["sig"] = "ZZSIG" + "A" * 24
            qs = ("?" + urlencode(q2)) if q2 else ""
            tail = "/f/%s/%s%s" % (token, name, qs)
            if kind == "rel":
                loc = tail
            elif kind == "evil":
                loc = "https://evilgithub.com" + tail
            elif kind == "suffix":
                loc = "https://release-assets.githubusercontent.com" + tail
            elif kind == "plainhttp":
                loc = "http://github.com" + tail
            else:
                loc = "http://127.0.0.1:%d%s" % (port, tail)
            rec["status"] = code
            log_line(rec)
            self._send(code, b"", {"Location": loc})
            return
        st = q.get("status")
        if st:
            rec["status"] = int(st)
            log_line(rec)
            self._send(int(st), b"error body")
            return
        if q.get("zero") == "1":
            rec["status"] = 200
            log_line(rec)
            self._send(200, b"")
            return
        if not os.path.isfile(payload_path):
            rec["status"] = 404
            log_line(rec)
            self._send(404, b"missing")
            return
        with open(payload_path, "rb") as f:
            data = f.read()
        total = len(data)
        start = 0
        code = 200
        hdrs = {}
        if rng and q.get("r416") == "1":
            rec["status"] = 416
            log_line(rec)
            self._send(416, b"", {"Content-Range": "bytes */%d" % total})
            return
        if rng and q.get("norange") != "1":
            mm = re.match(r"^bytes=(\d+)-$", rng.strip())
            if mm:
                start = int(mm.group(1))
                if start >= total:
                    rec["status"] = 416
                    log_line(rec)
                    self._send(416, b"", {"Content-Range": "bytes */%d" % total})
                    return
                code = 206
                hdrs["Content-Range"] = "bytes %d-%d/%d" % (start, total - 1, total)
        body = data[start:]
        clmis = int(q.get("clmis", "0") or 0)
        if clmis != 0:
            if clmis < 0:
                body = body[: max(0, len(body) + clmis)]
            else:
                body = body + b"\0" * clmis
        over = int(q.get("over", "0") or 0)
        cut = q.get("cut")
        do_cut = False
        if cut:
            with STATE_LOCK:
                if token not in FIRST_DONE:
                    FIRST_DONE.add(token)
                    do_cut = True
        slow = int(q.get("slow", "0") or 0) / 1000.0
        rec["status"] = code
        self.send_response(code)
        for k, v in hdrs.items():
            self.send_header(k, v)
        if q.get("nocl") != "1":
            self.send_header("Content-Length", str(len(body)) if over == 0 else str(len(body) + over))
        self.send_header("Connection", "close")
        self.end_headers()
        limit = len(body)
        stall = int(q.get("stall", "0") or 0)
        if stall > 0:
            limit = min(limit, stall * 1024)
        if do_cut:
            limit = int(len(body) * int(cut) / 100.0)
        sent = 0
        try:
            while sent < limit:
                part = body[sent: min(limit, sent + CHUNK)]
                self.wfile.write(part)
                self.wfile.flush()
                sent += len(part)
                if slow > 0:
                    time.sleep(slow)
            if stall > 0:
                time.sleep(8)
            if over > 0 and not do_cut:
                self.wfile.write(b"\1" * over)
                sent += over
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass
        rec["sent"] = sent
        rec["cut"] = bool(do_cut)
        log_line(rec)
        if do_cut:
            try:
                self.connection.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
        self.close_connection = True


def main():
    global ARGS
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, required=True)
    ap.add_argument("--root", required=True)
    ap.add_argument("--ttl", type=int, default=900, help="stop by itself after this many seconds")
    ARGS = ap.parse_args()
    os.makedirs(ARGS.root, exist_ok=True)
    srv = ThreadingHTTPServer(("127.0.0.1", ARGS.port), Handler)
    srv.daemon_threads = True
    with open(os.path.join(ARGS.root, "port.txt"), "w", encoding="utf-8") as f:
        f.write(str(srv.server_address[1]))
    threading.Timer(ARGS.ttl, lambda: os._exit(0)).start()
    print("FAKE_MODEL_SERVER listening 127.0.0.1:%d" % srv.server_address[1], flush=True)
    try:
        srv.serve_forever()
    finally:
        srv.server_close()


if __name__ == "__main__":
    sys.exit(main())
