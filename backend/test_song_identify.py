# -*- coding: utf-8 -*-
"""Tests of POST /song/identify (song.py: title typed by the user -> up to 3 {title, artist} candidates). In-process: no server, no
port, no model, no network. The AI is a fake injected as `llm_json`; nothing real is ever called.

  .venv\\Scripts\\python.exe -I test_song_identify.py
  .venv\\Scripts\\python.exe -I test_song_identify.py --stub PORT --lrclib PORT2
        additionally starts lan_stub_server.py --song on PORT and godot/tests/fixtures/song/fake_lrclib.py on PORT2 (both 127.0.0.1,
        both must be free), checks the stub's /song/identify (nothing -> [], down -> 503, else a song the fake LRCLIB really finds)

Last line:  == test_song_identify: N passed, 0 failed ==   (exit 0)
"""
import logging
import os
import socket
import subprocess
import sys
import tempfile
import threading
import time

os.environ["HOEHWA_TEST_HOOKS"] = "1"
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import httpx  # noqa: E402
from fastapi import FastAPI  # noqa: E402
from starlette.testclient import TestClient  # noqa: E402

import lan  # noqa: E402
import song  # noqa: E402

PASSED, FAILED = [], []


def ok(name, cond, detail=""):
    (PASSED if cond else FAILED).append(name)
    print("  [%s] %s%s" % ("PASS" if cond else "FAIL", name, (" -- " + str(detail)[:300]) if (detail != "" and not cond) else ""))
    return bool(cond)


def arg(name):
    return sys.argv[sys.argv.index(name) + 1] if name in sys.argv and sys.argv.index(name) + 1 < len(sys.argv) else None


# ---- a logger that records everything (to prove the typed text never reaches the log) ------------------------------------------
class Capture(logging.Handler):
    def __init__(self):
        logging.Handler.__init__(self, logging.DEBUG)
        self.lines = []

    def emit(self, record):
        try:
            self.lines.append(record.getMessage())
        except Exception as e:
            self.lines.append("LOGGING ERROR " + repr(e))


CAP = Capture()
LOG = logging.getLogger("identify_test")
LOG.setLevel(logging.DEBUG)
LOG.propagate = False
LOG.addHandler(CAP)


class FormatErr(Exception):
    """like server.ApiError(format_error=True): the AI answered without usable JSON"""
    format_error = True

    def __init__(self, msg):
        Exception.__init__(self, msg)
        self.msg = msg


class Fake:
    """scripted llm_json: `answer` is the data to return, or a callable(messages) -> data (it may raise)."""

    def __init__(self, answer):
        self.answer = answer
        self.calls = []

    def __call__(self, messages, schema, temperature=0.7, num_predict=1800, think=False, cache_key_kind="UNSET", validate=None, **kw):
        self.calls.append({"messages": messages, "schema": schema, "kind": cache_key_kind, "kw": kw})
        a = self.answer
        return a(messages) if callable(a) else a


def good(title="Kettle Morning", artist="Test Artist"):
    return {"title": title, "artist": artist}


fake = Fake({"cands": [good()]})
song.init(log=LOG, llm_json=fake, root=tempfile.mkdtemp(prefix="ident_"), fake_asr=True,
          **{k: v for k, v in song.fake_helpers().items() if k not in ("llm_json", "llm_calls")})
app = FastAPI()
app.include_router(song.router)
client = TestClient(app)


def ask(body, raw=None):
    r = client.post("/song/identify", content=raw if raw is not None else __import__("json").dumps(body).encode("utf-8"),
                    headers={"content-type": "application/json"})
    try:
        j = r.json()
    except Exception:
        j = None
    return r.status_code, j


def with_ai(answer):
    fake.answer = answer
    del fake.calls[:]
    return fake


# ---- 1. contract: 400 bad_q / 200 / 503 ---------------------------------------------------------------------------------------------
print("== contract ==")
for name, body in (("empty string", {"q": "", "lang": "en"}), ("only spaces", {"q": "   \t ", "lang": "en"}), ("121 chars", {"q": "a" * 121, "lang": "en"}),
                   ("121 chars after trimming one side only", {"q": " " + "a" * 121, "lang": ""}), ("missing q", {"lang": "en"}),
                   ("q is a number", {"q": 123, "lang": "en"}), ("q is null", {"q": None}), ("q is a list", {"q": ["x"]})):
    with_ai({"cands": [good()]})
    st, j = ask(body)
    ok("400 bad_q: " + name, st == 400 and j == {"error": "bad_q", "code": "bad_q"} and not fake.calls, (st, j))
st, j = ask(None, raw=b"not json at all")
ok("400 bad_request for a body that is not JSON", st == 400 and j.get("code") == "bad_request", (st, j))
st, j = ask({"q": "x", "lang": "ko"})
ok("400 for an unknown lang", st == 400 and j.get("code") == "bad_request", (st, j))
with_ai({"cands": [good()]})
st, j = ask({"q": "a" * 120, "lang": ""})
ok("120 chars is accepted (200)", st == 200 and j == {"ok": True, "cands": [good()]}, (st, j))
st, j = ask({"q": "  Kettle Morning  "})
ok("lang may be left out; q is trimmed in the prompt", st == 200 and "<<<Kettle Morning>>>" in fake.calls[-1]["messages"][0]["content"], (st, j))
for n in (0, 1, 2, 3):
    with_ai({"cands": [good("Song %d" % k, "Artist") for k in range(n)]})
    st, j = ask({"q": "x", "lang": "ja"})
    ok("200 with %d candidate(s)" % n, st == 200 and j["ok"] is True and len(j["cands"]) == n, (st, j))
with_ai({"cands": [good("Song 1", "A"), good("Song 2", "B")]})
st, j = ask({"q": "x"})
ok("answer keeps the AI's order", [c["title"] for c in j["cands"]] == ["Song 1", "Song 2"], j)


def boom(_m):
    raise RuntimeError("engine is down")


with_ai(boom)
st, j = ask({"q": "x"})
ok("503 ai_unavailable when the AI fails", st == 503 and j == {"error": "ai_unavailable", "code": "ai_unavailable"}, (st, j))
saved = song.H.pop("llm_json")
st, j = ask({"q": "x"})
ok("503 ai_unavailable when there is no AI engine at all", st == 503 and j.get("error") == "ai_unavailable", (st, j))
song.H["llm_json"] = saved


def api502(_m):
    raise song.H["ApiError"]("Der AI engine says no", 502) if "ApiError" in song.H else RuntimeError("x")


with_ai(api502)
st, j = ask({"q": "x"})
ok("503 ai_unavailable when the engine reports an ApiError 502 (not a format error)", st == 503 and j.get("error") == "ai_unavailable", (st, j))


def fmt(_m):
    raise FormatErr("not JSON")


with_ai(fmt)
st, j = ask({"q": "x"})
ok("an unusable-JSON answer (format error) -> 200 cands []", st == 200 and j == {"ok": True, "cands": []}, (st, j))


def slow(_m):
    time.sleep(1.5)
    return {"cands": [good()]}


old_to = song.IDENTIFY_TIMEOUT
song.IDENTIFY_TIMEOUT = 0.3
with_ai(slow)
t0 = time.time()
st, j = ask({"q": "x"})
ok("503 ai_unavailable when the AI takes too long (timeout)", st == 503 and j.get("error") == "ai_unavailable" and time.time() - t0 < 1.2, (st, j, time.time() - t0))
song.IDENTIFY_TIMEOUT = old_to
time.sleep(1.5)                                     # let the slow worker finish so its slot is free again
ok("the 30 s limit is the contract's value", old_to == 30.0, old_to)

# the slot limit: two slow calls hold both slots, a third is 429 (and never reaches the AI)
gate_ev = threading.Event()


def held(_m):
    gate_ev.wait(5)
    return {"cands": []}


with_ai(held)
res = []
ths = [threading.Thread(target=lambda: res.append(ask({"q": "x"}))) for _ in range(2)]
for t in ths:
    t.start()
time.sleep(0.5)
st3, j3 = ask({"q": "x"})
gate_ev.set()
for t in ths:
    t.join(10)
ok("a third simultaneous request gets 429 queue_full", st3 == 429 and j3.get("code") == "queue_full", (st3, j3))
ok("the two held requests still finish with 200", sorted(r[0] for r in res) == [200, 200], res)

# ---- 2. the AI's answer is never trusted ----------------------------------------------------------------------------------------------
print("== AI output validation ==")


def got(answer):
    with_ai(answer)
    st, j = ask({"q": "x"})
    return st, (j or {}).get("cands")


lyric_title = "I walked down to the river where the kettle sings its morning song and the steam rises over every single hill ok"
ok("test title really is 101 chars", len(lyric_title[:101]) == 101 and len("t" * 101) == 101)
cases = [
    ("broken JSON (a string)", "{\"cands\": [{\"title\": \"Kett", []),
    ("answer is None", None, []),
    ("answer is a list, not an object", [good()], []),
    ("cands is a string", {"cands": "Kettle Morning"}, []),
    ("cands is an object", {"cands": good()}, []),
    ("no cands key", {"songs": [good()]}, []),
    ("title of 101 chars (lyrics-like) is dropped", {"cands": [good("t" * 101, "A")]}, []),
    ("title of exactly 100 chars is kept", {"cands": [good("t" * 100, "A")]}, [good("t" * 100, "A")]),
    ("lyric-like long sentence (> 100) dropped, good one kept", {"cands": [good(lyric_title * 2, "A"), good("Real Title", "A")]}, [good("Real Title", "A")]),
    ("title with a newline is dropped", {"cands": [good("Line one\nLine two", "A")]}, []),
    ("title with a CR is dropped", {"cands": [good("a\rb", "A")]}, []),
    ("title with a tab is dropped", {"cands": [good("a\tb", "A")]}, []),
    ("artist with a newline is dropped", {"cands": [good("T", "A\nB")]}, []),
    ("title ending in a newline is dropped too", {"cands": [good("Title\n", "A")]}, []),
    ("empty title is dropped", {"cands": [good("", "A")]}, []),
    ("title of only spaces is dropped", {"cands": [good("   ", "A")]}, []),
    ("numeric title is dropped", {"cands": [{"title": 123, "artist": "A"}]}, []),
    ("bool title is dropped", {"cands": [{"title": True, "artist": "A"}]}, []),
    ("list title is dropped", {"cands": [{"title": ["a"], "artist": "A"}]}, []),
    ("missing title is dropped", {"cands": [{"artist": "A"}]}, []),
    ("numeric artist is dropped", {"cands": [{"title": "T", "artist": 5}]}, []),
    ("artist of 81 chars is dropped", {"cands": [good("T", "a" * 81)]}, []),
    ("artist of 80 chars is kept", {"cands": [good("T", "a" * 80)]}, [good("T", "a" * 80)]),
    ("missing / null / empty artist is allowed as ''", {"cands": [{"title": "T1"}, {"title": "T2", "artist": None}, {"title": "T3", "artist": ""}]},
     [good("T1", ""), good("T2", ""), good("T3", "")]),
    ("items that are not objects are skipped", {"cands": ["Kettle Morning", 5, None, good("Ok", "A")]}, [good("Ok", "A")]),
    ("duplicates (case and spaces ignored) are dropped", {"cands": [good("Kettle Morning", "Test Artist"), good("kettle  morning", "TEST ARTIST"),
                                                                  good(" KETTLEMORNING ", "testartist"), good("Other", "Test Artist")]},
     [good("Kettle Morning", "Test Artist"), good("Other", "Test Artist")]),
    ("same title with another artist is not a duplicate", {"cands": [good("Same", "A"), good("Same", "B")]}, [good("Same", "A"), good("Same", "B")]),
    ("5 candidates -> the first 3", {"cands": [good("S%d" % k, "A") for k in range(5)]}, [good("S%d" % k, "A") for k in range(3)]),
    ("an invalid one does not use up a slot of the 3", {"cands": [good("a\nb", "A")] + [good("S%d" % k, "A") for k in range(4)]}, [good("S%d" % k, "A") for k in range(3)]),
    ("keys other than title / artist are dropped", {"cands": [{"title": "T", "artist": "A", "lyrics": "la la la", "note": "x", "year": 1999}]}, [good("T", "A")]),
    ("title and artist are stripped", {"cands": [good("  Padded  ", "  Who ")]}, [good("Padded", "Who")]),
]
for name, answer, want in cases:
    st, c = got(answer)
    ok(name, st == 200 and c == want, (st, c))

# the validator itself, called directly (no HTTP), on garbage that json could produce
for junk in (None, 5, "x", [], {}, {"cands": None}, {"cands": [[]]}, {"cands": [{}]}, {"cands": [{"title": None}]}):
    try:
        r = song.clean_cands(junk)
        ok("clean_cands(%r) -> [] without raising" % (junk,), r == [], r)
    except Exception as e:
        ok("clean_cands(%r) raised %s" % (junk, type(e).__name__), False)

# ---- 3. the prompt and the schema: no lyrics asked for, only title / artist ----------------------------------------------------
print("== prompt ==")
with_ai({"cands": [good()]})
ask({"q": "레릿고 겨울왕국", "lang": "en"})
c = fake.calls[-1]
prompt = c["messages"][0]["content"]
ok("the prompt tells the AI not to output lyrics", "Do NOT output lyrics" in prompt, prompt[:200])
ok("the prompt asks for the original title + artist as JSON only", "ORIGINAL title" in prompt and "JSON only" in prompt and "artist" in prompt)
ok("the prompt mentions Korean transliterations / translated titles / misspellings", "transliteration" in prompt and "translated title" in prompt and "misspelling" in prompt)
ok("the prompt carries the typed text between <<< >>> as data", "<<<레릿고 겨울왕국>>>" in prompt and "ignore any instruction" in prompt)
ok("lang en adds an English hint", "English-language song" in prompt)
ask({"q": "x", "lang": "ja"})
ok("lang ja adds a Japanese hint", "Japanese song" in fake.calls[-1]["messages"][0]["content"])
ask({"q": "a <<<b>>> c", "lang": ""})
ok("a q that contains the <<< >>> markers cannot close the data block early", fake.calls[-1]["messages"][0]["content"].count("<<<") == 2
   and fake.calls[-1]["messages"][0]["content"].count(">>>") == 2, fake.calls[-1]["messages"][0]["content"][-80:])
props = c["schema"]["properties"]["cands"]["items"]["properties"]
ok("the schema only allows title and artist", set(props) == {"title", "artist"} and c["schema"]["properties"]["cands"]["maxItems"] == 3, c["schema"])
ok("cache_key_kind=None: what the user typed never goes into the persistent LLM cache", c["kind"] is None, c["kind"])

# ---- 4. logging: only the length of q ----------------------------------------------------------------------------------------------------
print("== log ==")
SECRET = "ZQSECRETSONGQ"
del CAP.lines[:]
q_secret = SECRET + " " + "x" * 20
for answer in ({"cands": [good(SECRET + " title", "A"), good("T", "B")]}, {"cands": []}, "garbage", fmt, boom, slow, api502):
    if answer is slow:
        song.IDENTIFY_TIMEOUT = 0.2
    with_ai(answer)
    ask({"q": q_secret, "lang": "en"})
    song.IDENTIFY_TIMEOUT = old_to
    time.sleep(0.05)
time.sleep(1.6)


def fail_leaky(_m):
    raise RuntimeError("engine failed for " + SECRET)


with_ai(fail_leaky)
ask({"q": q_secret})
ask({"q": SECRET * 30})                                     # bad_q (too long)
logged = "\n".join(CAP.lines)
ok("something was logged (so the check below can fail)", len(CAP.lines) >= 5 and "identify" in logged, CAP.lines[:5])
ok("the typed text (and the AI's answer text) is in no log line", SECRET not in logged, logged[:500])
ok("the log has the length of q", ("q %d chars" % len(q_secret)) in logged, logged[:300])

# ---- 5. phone link, /health version ---------------------------------------------------------------------------------------------------------
print("== lan / health ==")
ok("lan.ALLOW has (POST, /song/identify)", ("POST", "/song/identify") in lan.ALLOW)
ok("only POST is allowed for it (no GET)", ("GET", "/song/identify") not in lan.ALLOW)
ok("song.SONG_V stays 1 (/health song_v and the song JSON v; an old app must not see app_old)", song.SONG_V == 1 and not hasattr(song, "SONG_API_V"), song.SONG_V)
srv = open(os.path.join(HERE, "server.py"), encoding="utf-8").read()
ok("server.py /health has song_v from song.SONG_V and song_identify true, and injects llm_json into song.init", '"song_v": song.SONG_V, "song_identify": True}' in srv
   and "song.init(log=log, ApiError=ApiError, readmode=readmode, llm_json=llm_json" in srv)

# ---- 6. stub over real HTTP (optional) ---------------------------------------------------------------------------------------------------------
def nobody_listens(p):
    s_ = socket.socket()
    s_.settimeout(1)
    try:
        return s_.connect_ex(("127.0.0.1", p)) != 0
    finally:
        s_.close()


def port_free(p):
    s_ = socket.socket()
    try:
        s_.bind(("127.0.0.1", p))
        return True
    except OSError:
        return False
    finally:
        s_.close()


if arg("--stub") and arg("--lrclib"):
    p1, p2 = int(arg("--stub")), int(arg("--lrclib"))
    print("== stub (%d) and fake LRCLIB (%d) over real HTTP ==" % (p1, p2))
    if p1 in (8770, 8775, 8776) or p2 in (8770, 8775, 8776):
        sys.exit("refusing the app's real ports")
    if not (port_free(p1) and port_free(p2)):
        ok("stub / lrclib ports are free", False, (p1, p2))
    else:
        tmp = tempfile.mkdtemp(prefix="ident_stub_")
        env = dict(os.environ, HOEHWA_TEST_HOOKS="1")
        fx = os.path.normpath(os.path.join(HERE, "..", "godot", "tests", "fixtures", "song", "fake_lrclib.py"))
        procs = []
        try:
            procs.append(subprocess.Popen([sys.executable, "-I", os.path.join(HERE, "lan_stub_server.py"), "--port", str(p1), "--tag", "identstub",
                                           "--devices-file", os.path.join(tmp, "dev.json"), "--song", "--song-dir", os.path.join(tmp, "jobs")],
                                          stdout=open(os.path.join(tmp, "stub.out"), "wb"), stderr=subprocess.STDOUT, cwd=HERE, env=env))
            procs.append(subprocess.Popen([sys.executable, "-I", fx, "--port", str(p2)], stdout=open(os.path.join(tmp, "lrc.out"), "wb"),
                                          stderr=subprocess.STDOUT, cwd=os.path.dirname(fx)))
            base, lrc = "http://127.0.0.1:%d" % p1, "http://127.0.0.1:%d" % p2
            up = 0
            t0 = time.time()
            while time.time() - t0 < 30 and up < 2:
                up = 0
                for u in (base + "/health", lrc + "/_ping"):
                    try:
                        up += httpx.get(u, timeout=1).status_code == 200
                    except Exception:
                        pass
                if up < 2:
                    time.sleep(0.3)
            ok("stub and fake LRCLIB are up", up == 2)
            if up == 2:
                h = httpx.get(base + "/health").json()
                ok("stub /health: song true, song_v 1, song_identify true", h.get("song") is True and h.get("song_v") == 1 and h.get("song_identify") is True, h)
                H = {"content-type": "application/json"}
                r = httpx.post(base + "/song/identify", content=b'{"q": "this is nothing", "lang": "en"}', headers=H)
                ok("stub: q with 'nothing' -> 200 cands []", r.status_code == 200 and r.json() == {"ok": True, "cands": []}, r.text)
                r = httpx.post(base + "/song/identify", content=b'{"q": "service down", "lang": "en"}', headers=H)
                ok("stub: q with 'down' -> 503 ai_unavailable", r.status_code == 503 and r.json().get("error") == "ai_unavailable", r.text)
                r = httpx.post(base + "/song/identify", content='{"q": "케틀 모닝", "lang": "en"}'.encode("utf-8"), headers=H)
                cs = r.json().get("cands") if r.status_code == 200 else None
                ok("stub: any other q -> one fixed candidate", cs == [{"title": "Kettle Morning", "artist": "Test Artist"}], r.text)
                r = httpx.post(base + "/song/identify", content=b'{"q": ""}', headers=H)
                ok("stub: empty q -> 400 bad_q", r.status_code == 400 and r.json().get("error") == "bad_q", r.text)
                if cs:
                    rr = httpx.get(lrc + "/api/get", params={"track_name": cs[0]["title"], "artist_name": cs[0]["artist"]})
                    ok("the fixed candidate is a song the fake LRCLIB really finds (/api/get 200, has lyrics)", rr.status_code == 200 and bool(rr.json().get("syncedLyrics")), rr.text[:200])
        finally:
            for p in procs:
                try:
                    p.terminate()
                    p.wait(10)
                except Exception:
                    try:
                        p.kill()
                    except Exception:
                        pass
        time.sleep(0.5)
        ok("stub and fake LRCLIB stopped (nobody listens on the ports any more)", all(pr.poll() is not None for pr in procs) and nobody_listens(p1) and nobody_listens(p2), ([pr.poll() for pr in procs], nobody_listens(p1), nobody_listens(p2)))

print("\n== test_song_identify: %d passed, %d failed ==" % (len(PASSED), len(FAILED)))
if FAILED:
    print("FAILED:", "; ".join(FAILED))
sys.exit(1 if FAILED else 0)
