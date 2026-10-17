# -*- coding: utf-8 -*-
"""Fake backend for developing / testing the phone link WITHOUT any model: same LAN layer as server.py (lan.py), canned answers.

  .venv\\Scripts\\python.exe lan_stub_server.py --port 8830 [--tag w2] [--lan-bind 0.0.0.0] [--devices-file PATH]
                                              [--lan-port 8840] [--lan-discovery-port 18776] [--lan-enabled]

  --port                 loopback HTTP port (127.0.0.1). Never the app's own server port.
  --lan-port / --lan-discovery-port   what POST /lan {"enabled":true} binds when it names no port (defaults 8840 / 18776,
                         NOT the real 8775 / 8776, so a stub never collides with the user's app)
  --lan-enabled          start with the phone link already on (like a saved "enabled": true)
  --devices-file         where tokens (SHA-256 only) are kept; default backend\\lan_devices-<tag>.json (git-ignored)
  --tag                  names the default devices file

Answers: /health /stt /tts(0.3 s WAV) /score /prosody /chat /mic/start /llm(POST) and the rest of the phone allow-list, plus
lan.router (/hello /pair /lan ...). Prints "STUB_READY ..." on stdout once the app is up. Everything is fake: do not judge quality with it.
"""
import argparse
import io
import logging
import math
import os
import struct
import sys
import wave
from contextlib import asynccontextmanager

BASE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, BASE)

import uvicorn
from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse, Response
from starlette.exceptions import HTTPException as StarletteHTTPException

import lan

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
ap.add_argument("--port", type=int, required=True)
ap.add_argument("--tag", default="")
ap.add_argument("--lan-bind", default="0.0.0.0")
ap.add_argument("--devices-file", default="")
ap.add_argument("--lan-port", type=int, default=8840)
ap.add_argument("--lan-discovery-port", type=int, default=18776)
ap.add_argument("--lan-enabled", action="store_true")
ap.add_argument("--allow-real-ports", action="store_true", help="allow the app's real ports (never do this next to the app)")
ARGS = ap.parse_args()
APP_PORT = 8700 + 70    # the app's own backend port (written this way on purpose: tests must never mention or use it)
if not ARGS.allow_real_ports and (ARGS.port == APP_PORT or ARGS.lan_port == lan.DEFAULT_LAN["port"] or ARGS.lan_discovery_port == lan.DEFAULT_LAN["discovery_port"]):
    sys.exit("refusing the app's real ports (backend / phone link / discovery): pick other ports")

log = logging.getLogger("stub")
log.setLevel(logging.INFO)
_h = logging.StreamHandler(sys.stderr)
_h.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(message)s"))
log.addHandler(_h)

CFG = {"lan": dict(lan.DEFAULT_LAN, enabled=bool(ARGS.lan_enabled), port=ARGS.lan_port, discovery_port=ARGS.lan_discovery_port)}


@asynccontextmanager
async def lifespan(app_):
    lan.start_if_enabled()
    print("STUB_READY pid=%d port=%d lan_port=%d lan_discovery_port=%d lan_enabled=%s" % (
        os.getpid(), ARGS.port, CFG["lan"]["port"], CFG["lan"]["discovery_port"], CFG["lan"]["enabled"]), flush=True)
    yield
    lan.shutdown()


app = FastAPI(title="Phone link stub backend", lifespan=lifespan)
lan.attach(app, CFG, lambda cfg: None, log, BASE, tag=ARGS.tag or None, devices_file=ARGS.devices_file or None, bind=ARGS.lan_bind,
           persist=False, auto_start=True)


@app.exception_handler(RequestValidationError)
async def _validation_error(request: Request, exc: RequestValidationError):
    return JSONResponse({"error": "요청 형식이 올바르지 않아요."}, status_code=422)


@app.exception_handler(StarletteHTTPException)
async def _http_error(request: Request, exc: StarletteHTTPException):
    msg = "찾을 수 없는 주소예요." if exc.status_code == 404 else "요청을 처리할 수 없어요."
    return JSONResponse({"error": msg}, status_code=exc.status_code)


def _wav(seconds=0.3, rate=24000):
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        n = int(seconds * rate)
        w.writeframes(b"".join(struct.pack("<h", int(6000 * math.sin(2 * math.pi * 440 * i / rate))) for i in range(n)))
    return buf.getvalue()


WAV = _wav()


@app.get("/health")
def health():
    return {"ok": True, "stub": True, "stt": True, "tts": {"en": True, "ja": True}, "tts_device": "cpu", "llm": True,
            "llm_model": "stub", "llm_provider": "opencode", "score": True, "phoneme": True, "tatoeba": True, "grammar": True,
            "llm_fallback": {"active": False, "until": None, "reason": ""}}


@app.get("/curriculum")
def curriculum():
    return {"en": {"months": [], "roadmap": {"header": [], "rows": []}}, "ja": {"months": [], "roadmap": {"header": [], "rows": []}}}


@app.post("/tts")
async def tts(request: Request):
    await request.body()
    return Response(content=WAV, media_type="audio/wav")


@app.get("/tts/voices")
def tts_voices():
    return {"voices": {"en": [{"id": "af_heart", "name": "Heart", "gender": "female", "default": True}],
                       "ja": [{"id": "jf_alpha", "name": "Alpha", "gender": "female", "default": True}]},
            "default": {"en": "af_heart", "ja": "jf_alpha"}}


@app.post("/stt")
async def stt(request: Request):
    raw = await request.body()
    return {"text": "this is a stub", "words": [{"w": "stub", "p": 0.9, "start": 0.0, "end": 0.3}], "duration": 0.3, "bytes": len(raw)}


@app.post("/score")
async def score(request: Request):
    await request.body()
    return {"transcript": "stub", "score": 88, "accuracy": 90, "clarity": 85, "fluency": 80,
            "units": [{"t": "stub", "ok": True, "conf": 0.9, "heard": None}], "tips_ko": ["스텁 서버의 가짜 점수예요."]}


@app.post("/prosody")
async def prosody(request: Request):
    await request.body()
    return {"native": {"t": [0.0, 0.5, 1.0], "f0": [0.0, 1.0, -1.0], "dur": 0.3}, "mine": None, "similarity": None, "accent": None,
            "mine_accent": None, "tips_ko": []}


@app.post("/chat")
async def chat(request: Request):
    await request.body()
    return {"reply": "Hello! (stub)", "reading": "", "ko": "안녕하세요! (스텁)", "fix": "", "fix_ko": "", "suggest": ["Hi!", "Hello!"],
            "tts_chunks": ["Hello!", "(stub)"]}


@app.post("/feedback")
async def feedback(request: Request):
    await request.body()
    return {"scores": {"fluency": 3, "accuracy": 3, "vocabulary": 3}, "summary": "스텁 서버의 가짜 평가예요.", "corrections": [], "phrases": []}


@app.post("/fix")
async def fix(request: Request):
    await request.body()
    return {"fix": "", "fix_ko": ""}


@app.post("/lesson")
async def lesson(request: Request):
    await request.body()
    return {"exercises": [], "source": "stub"}


@app.post("/reading/analyze")
async def reading_analyze(request: Request):
    await request.body()
    return {"sentences": []}


@app.post("/reading/gloss")
async def reading_gloss(request: Request):
    await request.body()
    return {"gloss": "스텁"}


@app.get("/examples")
def examples():
    return {"examples": []}


# ---- things the phone must NOT reach through the LAN listener (the stub has them so a 403 is not just a 404) ----
@app.get("/mic/devices")
def mic_devices():
    return {"devices": ["stub mic"], "default": "stub mic"}


@app.post("/mic/start")
async def mic_start(request: Request):
    await request.body()
    return {"ok": True}


@app.get("/mic/level")
def mic_level():
    return {"recording": False, "level": 0.0}


@app.post("/mic/stop")
def mic_stop():
    return {"ok": False, "b64": "", "duration": 0.0, "silent": True}


@app.post("/mic/cancel")
def mic_cancel():
    return {"ok": True}


@app.get("/llm")
def llm_get():
    return {"provider": "opencode", "options": [{"id": "opencode", "label": "stub", "available": True}], "llm_fallback": {"active": False}}


@app.post("/llm")
async def llm_post(request: Request):
    await request.body()
    return {"provider": "opencode"}


@app.get("/debug/ping")
def debug_ping():
    return {"ok": True}


if __name__ == "__main__":
    uvicorn.run(app, host="127.0.0.1", port=ARGS.port, log_config=None, access_log=False)
