# -*- coding: utf-8 -*-
"""PI2a: golden files for the phone's AI prompts and answer checks (docs/v200_phone_design.md 2.5, 6.11).

The phone (GDScript, v2.0.2) talks to the AI vendor directly and must build the same prompts and judge the answers the same way as
backend\\server.py. This tool CALLS the server functions in the same process (nothing is copied here) and writes what they did:
the messages / schema / temperature sent to the engine, the engine answer it was given, and the result. The GDScript tests read
those files and must reproduce them.

  --write   (default) write godot\\tests\\fixtures\\ai_golden\\*.json from phone_src\\tools\\ai_golden_cases.json
  --check   build the same data in memory and compare with the files on disk. Different -> "GOLDEN_DRIFT <case>" per case, exit 1.
            (the server changed: update the GDScript copy, then run --write)
  --list    print the number of cases per kind

Exit code: 0 ok, 1 drift / missing file, 2 bad cases file or a case that cannot run.

Safety (docs 6.11 PI2a-4): no network, no model, no port, no server process, nothing written under backend\\.
  - socket creation, name lookup and subprocess start are blocked while the generator runs (and the first engine call probes it)
  - the server's AI engine call is replaced by a scripted fake that RECORDS what it was given; the cache is switched off
  - importing server.py makes its log/cache folders and writes bytecode: those calls are skipped for paths under backend\\
Run:  <repo>\\..\\app\\backend\\.venv\\Scripts\\python.exe -I -X utf8 phone_src\\tools\\make_ai_golden.py --check
"""
import contextlib
import copy
import json
import os
import platform
import shutil
import socket
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True   # no backend\__pycache__ (and none next to this file)

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
BACKEND = os.path.join(ROOT, "backend")
CASES_PATH = os.path.join(HERE, "ai_golden_cases.json")
OUT_DIR = os.path.join(ROOT, "godot", "tests", "fixtures", "ai_golden")

# case kind -> output file (the file holds every case of its kinds, in the order of the cases file)
KIND_FILE = {
    "chat": "chat.json", "fix": "fix.json", "feedback": "feedback.json", "judge": "judge.json",
    "ko": "ko_text.json", "clean_hist": "clean_hist.json", "question": "question.json",
    "extract_json": "extract_json.json", "norm_text": "norm_text.json",
    "rules": "prompts.json", "context": "prompts.json", "api": "api_call.json",
}
FORMAT_VERSION = 1


class GoldenError(Exception):
    """a case that cannot run (bad cases file, script too short ...): exit 2"""


class NetworkBlocked(RuntimeError):
    """socket / name lookup / process start while the generator runs"""


STATE = {"server": None, "socket_probe": None}   # socket_probe: True once an engine call saw socket creation fail


# ------------------------------------------------------------------------------------------------ safety guards
@contextlib.contextmanager
def no_network():
    """socket creation, name lookup and subprocess start raise NetworkBlocked inside this block"""
    def _blocked(*a, **k):
        raise NetworkBlocked("network / process access is blocked while the golden generator runs")
    platform.uname()   # numpy reads the OS name at import, which starts `ver` on Windows the first time: do it before the guard
    saved = (socket.socket.__init__, socket.getaddrinfo, socket.create_connection, subprocess.Popen.__init__)
    socket.socket.__init__ = _blocked
    socket.getaddrinfo = _blocked
    socket.create_connection = _blocked
    subprocess.Popen.__init__ = _blocked
    try:
        yield
    finally:
        socket.socket.__init__, socket.getaddrinfo, socket.create_connection, subprocess.Popen.__init__ = saved


def _probe_socket():
    """True when a socket cannot be made right now (called from the fake engine, i.e. in the middle of a server call)"""
    try:
        socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    except NetworkBlocked:
        return True
    except Exception:
        return False
    return False


def _under_backend(path):
    try:
        p = os.path.abspath(os.fspath(path))
    except Exception:
        return False
    b = os.path.abspath(BACKEND)
    return p == b or p.startswith(b + os.sep)


@contextlib.contextmanager
def keep_backend_clean():
    """importing server.py calls os.makedirs for backend\\models\\hf, logs, cache\\tts: skip those (nothing is created under backend\\)"""
    real = os.makedirs

    def makedirs(name, mode=0o777, exist_ok=False):
        if _under_backend(name):
            return None
        return real(name, mode, exist_ok)
    os.makedirs = makedirs
    try:
        yield
    finally:
        os.makedirs = real


def load_server():
    """import backend\\server.py once, in this process (no port is opened: only a server PROCESS does that)"""
    if STATE["server"] is not None:
        return STATE["server"]
    sys.dont_write_bytecode = True
    tmp = tempfile.mkdtemp(prefix="hoehwa_aigolden_")
    os.environ["HOEHWA_ESPEAK_DIR"] = os.path.join(tmp, "espeak")
    saved_argv = sys.argv
    sys.argv = [saved_argv[0], "--tag", "golden_ai"]   # server.py reads sys.argv for --port / --prefetch / --tag
    if BACKEND not in sys.path:
        sys.path.insert(0, BACKEND)
    try:
        with keep_backend_clean():
            import llm_cache
            import server
            import missions
            import llm_api
            import llm_common
    finally:
        sys.argv = saved_argv
        shutil.rmtree(tmp, ignore_errors=True)
    STATE["server"] = server
    return server


# ------------------------------------------------------------------------------------------------ fake engines
class ScriptedEngine:
    """replaces server._remote_json(messages, schema, temperature, num_predict): records every call and answers from the script.
    A script step is {"reply": {...}} or {"error": {"kind": "limit|auth|overload|not_connected|format|plain", "msg": "...", "status": 502}}."""

    def __init__(self, case, script):
        import llm_common
        self.llm_common = llm_common
        self.case = case
        self.script = list(script or [])
        self.calls = []

    def __call__(self, messages, schema, temperature, num_predict):
        if STATE["socket_probe"] is None:
            STATE["socket_probe"] = _probe_socket()
        if not self.script:
            raise GoldenError("case %s: the server made engine call %d but the script has only %d step(s)"
                              % (self.case, len(self.calls) + 1, len(self.calls)))
        step = self.script.pop(0)
        rec = {"messages": copy.deepcopy(messages), "schema": copy.deepcopy(schema), "temperature": temperature,
               "num_predict": num_predict}
        if "error" in step:
            e = step["error"]
            kind = e.get("kind", "plain")
            msg = e.get("msg", "")
            if not msg and kind != "format":
                raise GoldenError("case %s: an error step needs a msg (an empty one makes the server print the clock)" % self.case)
            rec["error"] = {"kind": kind, "msg": msg, "status": e.get("status", 502)}
            self.calls.append(rec)
            if kind == "format":
                raise self.llm_common.LlmError(self.llm_common.FORMAT_MSG, 502, None, "")
            llm_kind = None if kind == "plain" else kind
            raise self.llm_common.LlmError(msg, e.get("status", 502), llm_kind, e.get("raw", "engine said so"))
        reply = copy.deepcopy(step["reply"])
        rec["reply"] = copy.deepcopy(reply)
        self.calls.append(rec)
        return reply


def _api_error_dict(e):
    return {"status": e.status, "msg": e.msg, "code": e.code, "format_error": bool(e.format_error)}


def _outcome(fn):
    """run fn() -> ({"result": ...} | {"error": {...}} | {"exception": "TypeName"})"""
    S = load_server()
    try:
        return {"result": fn()}
    except S.ApiError as e:
        return {"error": _api_error_dict(e)}
    except (GoldenError, NetworkBlocked):
        raise
    except Exception as e:   # the server crashed on this input: that is behaviour too (the phone must not crash the same way)
        return {"exception": type(e).__name__}


@contextlib.contextmanager
def fake_engine(case, script):
    """provider openai_api, the engine and the cache replaced; everything is put back afterwards"""
    S = load_server()
    import llm_cache
    import llm_fallback
    eng = ScriptedEngine(case, script)
    saved = (S._remote_json, S.CFG.get("llm_provider"), S.grammar.correct, llm_cache.get, llm_cache.put)
    S._remote_json = eng
    S.CFG["llm_provider"] = "openai_api"
    S.grammar.correct = lambda *a, **k: None        # no LanguageTool on the phone: correct_learner always goes to the AI
    llm_cache.get = lambda key: None                # no cache (the phone has none): every call reaches the engine
    llm_cache.put = lambda *a, **k: None
    llm_fallback.clear()
    try:
        yield eng
    finally:
        S._remote_json = saved[0]
        if saved[1] is None:
            S.CFG.pop("llm_provider", None)
        else:
            S.CFG["llm_provider"] = saved[1]
        S.grammar.correct, llm_cache.get, llm_cache.put = saved[2], saved[3], saved[4]
        llm_fallback.clear()
        if eng.script:
            raise GoldenError("case %s: %d script step(s) were not used" % (case, len(eng.script)))


def _engine_case(case, run):
    """shared body of chat / fix / feedback / judge: run() inside the fake engine -> the golden record"""
    with fake_engine(case["case"], case.get("script")) as eng:
        out = _outcome(run)
    rec = {"case": case["case"], "kind": case["kind"], "req": copy.deepcopy(case["req"]), "engine": eng.calls,
           "expect": dict(out, attempts=len(eng.calls))}
    if case.get("note"):
        rec["note"] = case["note"]
    return rec


def _turns(S, history):
    return [S.Turn(role=h.get("role", "me"), text=h.get("text", "")) for h in (history or [])]


def run_chat(case):
    S = load_server()
    r = dict(case["req"])
    r["history"] = [dict(h) for h in r.get("history", [])]
    return _engine_case(case, lambda: S.run_chat(S.ChatReq(**r)))


def run_fix(case):
    S = load_server()
    return _engine_case(case, lambda: S.fix(S.FixReq(**case["req"])))


def run_feedback(case):
    S = load_server()
    return _engine_case(case, lambda: S.feedback(S.FeedbackReq(**case["req"])))


def run_judge(case):
    S = load_server()
    import missions
    return _engine_case(case, lambda: missions.missions_judge(missions.JudgeReq(**case["req"])))


# ------------------------------------------------------------------------------------------------ pure functions
def _plain(case, expect):
    rec = {"case": case["case"], "kind": case["kind"], "req": copy.deepcopy(case["req"]), "expect": expect}
    if case.get("note"):
        rec["note"] = case["note"]
    return rec


def run_ko(case):
    S = load_server()
    r = case["req"]
    lang = r.get("lang", "en")
    text = r["text"]
    return _plain(case, {"ko_ok": S.ko_ok(text, lang), "ko_ok_optional": S.ko_ok(text, lang, required=False),
                         "scrub_ko": S.scrub_ko(text, lang)})


def run_clean_hist(case):
    S = load_server()
    r = case["req"]
    turns = _turns(S, r["history"])
    out = S.clean_hist(turns, r["limit"]) if "limit" in r else S.clean_hist(turns)
    return _plain(case, {"result": out})


def run_question(case):
    S = load_server()
    r = case["req"]
    return _plain(case, {"result": S.looks_like_question(r["text"], r["lang"])})


def run_norm_text(case):
    S = load_server()
    r = case["req"]
    return _plain(case, {"result": S.norm_text(r["text"], r["lang"])})


def run_extract_json(case):
    import llm_common
    try:
        return _plain(case, {"ok": True, "data": llm_common.extract_json(case["req"]["text"])})
    except ValueError:
        return _plain(case, {"ok": False, "data": {}})


def run_rules(case):
    S = load_server()
    r = case["req"]
    return _plain(case, _outcome(lambda: S.rules_text(r["lang"], r.get("scenario"), r["stage"], r["month"], r["week"])))


def run_context(case):
    S = load_server()
    r = case["req"]
    return _plain(case, _outcome(lambda: S.context_text(r["lang"], r["month"], r["week"])))


class _FakeResponse:
    def __init__(self, step):
        self.status_code = step.get("status", 200)
        self._body = step.get("body")
        self.text = step.get("text", json.dumps(self._body, ensure_ascii=False) if self._body is not None else "")
        self.headers = dict(step.get("headers", {}))

    def json(self):
        if self._body is None:
            raise ValueError("no json")
        return self._body


def run_api(case):
    """llm_api.call_json with the HTTP post replaced: the request body the phone must send, and how it reads the answer"""
    S = load_server()
    import llm_api
    import llm_common
    r = case["req"]
    script = list(case.get("script") or [])
    sent = []

    def fake_post(s, key, body, timeout):
        if STATE["socket_probe"] is None:
            STATE["socket_probe"] = _probe_socket()
        if not script:
            raise GoldenError("case %s: more HTTP calls than script steps" % case["case"])
        sent.append({"url": s["base_url"] + "/chat/completions", "body": copy.deepcopy(body), "timeout": timeout,
                     "key_sent": bool(key)})
        return _FakeResponse(script.pop(0))

    saved = (llm_api._post, llm_api.get_key, set(llm_api._no_json_mode))
    llm_api._post = fake_post
    llm_api.get_key = lambda s: llm_api._Secret("golden-dummy-credential")
    llm_api._no_json_mode.clear()
    cfg = {"openai_api": {k: v for k, v in (r.get("settings") or {}).items()}}
    try:
        try:
            data, _dt, model = llm_api.call_json(cfg, r["messages"], r["schema"], temperature=r.get("temperature", 0.7),
                                                 max_tokens=r.get("max_tokens"), timeout=r.get("timeout", 120))
            out = {"result": {"data": data, "model": model}}
        except llm_common.LlmError as e:
            out = {"error": {"msg": e.msg, "status": e.status, "kind": e.kind, "raw": e.raw}}
        no_json = sorted(list(k) for k in llm_api._no_json_mode)
    finally:
        llm_api._post, llm_api.get_key = saved[0], saved[1]
        llm_api._no_json_mode.clear()
        llm_api._no_json_mode.update(saved[2])
    if script:
        raise GoldenError("case %s: %d HTTP script step(s) not used" % (case["case"], len(script)))
    return _plain(case, dict(out, http=sent, json_mode_off=no_json))


RUNNERS = {
    "chat": run_chat, "fix": run_fix, "feedback": run_feedback, "judge": run_judge, "ko": run_ko, "clean_hist": run_clean_hist,
    "question": run_question, "extract_json": run_extract_json, "norm_text": run_norm_text, "rules": run_rules,
    "context": run_context, "api": run_api,
}


# ------------------------------------------------------------------------------------------------ build / write / check
def load_cases(path=CASES_PATH):
    try:
        with open(path, encoding="utf-8") as f:
            doc = json.load(f)
    except (OSError, ValueError) as e:
        raise GoldenError("cases file %s cannot be read (%s)" % (path, type(e).__name__))
    cases = doc.get("cases") if isinstance(doc, dict) else None
    if not isinstance(cases, list) or not cases:
        raise GoldenError("cases file has no cases list")
    seen = set()
    for c in cases:
        if not isinstance(c, dict) or "case" not in c or c.get("kind") not in RUNNERS or "req" not in c:
            raise GoldenError("bad case entry: %s" % (str(c)[:80]))
        if c["case"] in seen:
            raise GoldenError("duplicate case name %s" % c["case"])
        seen.add(c["case"])
    return cases


def build(cases, errors_as_drift=False):
    """-> {file name: document}; runs every case against the server code that is loaded right now.
    errors_as_drift (--check): a case whose script no longer fits what the server asks (an engine call more or less than before)
    becomes a record that differs from the file -> GOLDEN_DRIFT <case>; without it (--write) the GoldenError stops the run."""
    load_server()
    docs = {}
    for c in cases:
        try:
            rec = RUNNERS[c["kind"]](c)
        except GoldenError as e:
            if not errors_as_drift:
                raise
            rec = {"case": c["case"], "kind": c["kind"], "generator_error": str(e)}
        fname = KIND_FILE[c["kind"]]
        docs.setdefault(fname, {"version": FORMAT_VERSION, "file": fname, "cases": []})["cases"].append(rec)
    return docs


def _dump(doc):
    return json.dumps(doc, ensure_ascii=False, indent=1) + "\n"


def write_files(docs, out_dir=OUT_DIR):
    os.makedirs(out_dir, exist_ok=True)
    for fname, doc in docs.items():
        with open(os.path.join(out_dir, fname), "w", encoding="utf-8", newline="\n") as f:
            f.write(_dump(doc))


def compare(docs, out_dir=OUT_DIR):
    """-> list of drift lines (GOLDEN_DRIFT <case> / GOLDEN_MISSING <file> / GOLDEN_EXTRA <file>); empty = same"""
    lines = []
    for fname, doc in docs.items():
        path = os.path.join(out_dir, fname)
        try:
            with open(path, encoding="utf-8") as f:
                disk = json.load(f)
        except (OSError, ValueError):
            lines.append("GOLDEN_MISSING %s" % fname)
            continue
        old = {c.get("case"): c for c in disk.get("cases", [])} if isinstance(disk, dict) else {}
        new = {c["case"]: c for c in doc["cases"]}
        for name, c in new.items():
            if old.get(name) != c:
                lines.append("GOLDEN_DRIFT %s" % name)
        for name in old:
            if name not in new:
                lines.append("GOLDEN_DRIFT %s" % name)
        if isinstance(disk, dict) and disk.get("version") != FORMAT_VERSION:
            lines.append("GOLDEN_DRIFT %s#version" % fname)
    if os.path.isdir(out_dir):
        for fname in sorted(os.listdir(out_dir)):
            if fname.endswith(".json") and fname not in docs:
                lines.append("GOLDEN_EXTRA %s" % fname)
    return lines


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    mode = "write"
    for a in argv:
        if a == "--check":
            mode = "check"
        elif a == "--write":
            mode = "write"
        elif a == "--list":
            mode = "list"
        else:
            print("usage: make_ai_golden.py [--write | --check | --list]")
            return 2
    STATE["socket_probe"] = None
    try:
        with no_network():
            cases = load_cases()
            if mode == "list":
                counts = {}
                for c in cases:
                    counts[c["kind"]] = counts.get(c["kind"], 0) + 1
                for k in sorted(counts):
                    print("%-13s %d" % (k, counts[k]))
                print("total         %d" % len(cases))
                return 0
            docs = build(cases, errors_as_drift=(mode == "check"))
            if STATE["socket_probe"] is not True:
                raise GoldenError("the socket guard was not seen during an engine call (probe=%r)" % STATE["socket_probe"])
        if mode == "write":
            write_files(docs)
            print("GOLDEN_WRITTEN files=%d cases=%d socket_blocked=1" % (len(docs), len(cases)))
            return 0
        drift = compare(docs)
        for line in drift:
            print(line)
        for doc in docs.values():
            for rec in doc["cases"]:
                if "generator_error" in rec:
                    print("GOLDEN_NOTE %s: %s" % (rec["case"], rec["generator_error"]))
        if drift:
            print("GOLDEN_FAIL drift=%d (the server changed: port the change to the GDScript copy, then run --write)" % len(drift))
            return 1
        print("GOLDEN_OK files=%d cases=%d socket_blocked=1" % (len(docs), len(cases)))
        return 0
    except GoldenError as e:
        print("GOLDEN_ERROR %s" % e)
        return 2


if __name__ == "__main__":
    sys.exit(main())
