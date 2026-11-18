# -*- coding: utf-8 -*-
"""PI2a tests (docs/v200_phone_design.md 6.11): phone_src\\tools\\make_ai_golden.py and its golden files.

  <repo>\\..\\app\\backend\\.venv\\Scripts\\python.exe -I -X utf8 phone_src\\tools\\test_make_ai_golden.py

Prints "N passed, M failed"; exit code 1 when anything fails. Covers: PI2a-1 (this file), PI2a-2 (--check is clean), PI2a-3 (case
counts and kinds), PI2a-4 (no socket / process while generating, backend\\ untouched by sha256), PI2a-5 (drift: the server code is
changed in memory and --check must exit 1 with GOLDEN_DRIFT <case>), PI2a-6 (the two curriculum.json files are the same).
Every checker that only ever saw good input also gets a wrong input ("selfcheck" lines). Writes only under a temp folder.
"""
import contextlib
import hashlib
import io
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True   # nothing is written next to the sources (no __pycache__ under phone_src or backend)

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
ROOT = os.path.dirname(os.path.dirname(HERE))
BACKEND = os.path.join(ROOT, "backend")
GOLDEN = os.path.join(ROOT, "godot", "tests", "fixtures", "ai_golden")
CASES = os.path.join(HERE, "ai_golden_cases.json")
GEN = os.path.join(HERE, "make_ai_golden.py")
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

results = []


def check(name, cond, detail=""):
    results.append((name, bool(cond)))
    print("  [%s] %s%s" % ("PASS" if cond else "FAIL", name, (" -- " + str(detail)[:300]) if detail != "" else ""))
    return bool(cond)


def selfcheck(name, cond, detail=""):
    """a checker that was fed a WRONG input must say so: cond is True when it did"""
    results.append((name, bool(cond)))
    print("  [%s] selfcheck FAIL-as-expected: %s%s" % ("PASS" if cond else "FAIL", name, (" -- " + str(detail).splitlines()[0][:160] if str(detail).strip() else "") if detail != "" else ""))


def tree_hashes(root):
    """{relative path: sha256 or "<dir>"} for everything under root (the whole tree, so a new file or folder shows up too)"""
    out = {}
    if not os.path.isdir(root):
        return out
    for dp, dn, fn in os.walk(root):
        for d in dn:
            out[os.path.relpath(os.path.join(dp, d), root)] = "<dir>"
        for f in fn:
            p = os.path.join(dp, f)
            with open(p, "rb") as fh:
                out[os.path.relpath(p, root)] = hashlib.sha256(fh.read()).hexdigest()
    return out


def run_py(args, code=None):
    env = dict(os.environ)
    env["PYTHONDONTWRITEBYTECODE"] = "1"
    cmd = [sys.executable, "-I", "-B", "-X", "utf8"] + (["-c", code] if code is not None else [GEN]) + list(args)
    p = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8", errors="replace", env=env, timeout=300)
    return p.returncode, p.stdout, p.stderr


BACKEND_BEFORE = tree_hashes(BACKEND)
BACKEND_PY_BEFORE = {k: v for k, v in BACKEND_BEFORE.items() if k.endswith(".py") and os.sep not in k}

import make_ai_golden as G  # noqa: E402


def load(name):
    with open(os.path.join(GOLDEN, name), encoding="utf-8") as f:
        return json.load(f)["cases"]


@contextlib.contextmanager
def patched(obj, name, new):
    old = getattr(obj, name)
    setattr(obj, name, new)
    try:
        yield
    finally:
        setattr(obj, name, old)


def check_inproc(outdir=None):
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        rc = G.main(["--check"])
    return rc, buf.getvalue()


# ================================================================== PI2a-2: --check on the files in the repository (a real process)
print("== PI2a-2 --check (separate process)")
rc, out, err = run_py(["--check"])
check("PI2a-2 make_ai_golden.py --check exits 0", rc == 0, (out + err)[-300:])
check("PI2a-2 summary line GOLDEN_OK with socket_blocked=1", re.search(r"GOLDEN_OK files=11 cases=\d+ socket_blocked=1", out) is not None, out[-200:])
check("PI2a-2 no GOLDEN_DRIFT / GOLDEN_MISSING in the output", "GOLDEN_DRIFT" not in out and "GOLDEN_MISSING" not in out)
rc2, out2, _ = run_py(["--bogus"])
check("usage error exits 2", rc2 == 2 and "usage" in out2, out2[:100])

# ================================================================== PI2a-4: no network, nothing under backend
print("== PI2a-4 socket guard and backend untouched")
with G.no_network():
    blocked = {}
    for nm, fn in (("socket", lambda: socket.socket(socket.AF_INET, socket.SOCK_STREAM)), ("getaddrinfo", lambda: socket.getaddrinfo("localhost", 80)),
                   ("create_connection", lambda: socket.create_connection(("127.0.0.1", 9), 0.1)),
                   ("subprocess", lambda: subprocess.Popen([sys.executable, "-c", "pass"]))):
        try:
            fn()
            blocked[nm] = False
        except G.NetworkBlocked:
            blocked[nm] = True
        except Exception as e:   # a different error means the guard did not stop it
            blocked[nm] = "other:" + type(e).__name__
check("guard blocks socket creation, name lookup, connect and process start", all(v is True for v in blocked.values()), blocked)
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.close()
check("guard is removed afterwards (an unbound socket can be made again)", True)
selfcheck("a socket made while the guard is OFF is not blocked (the guard test can tell the difference)", s.fileno() == -1)

STATE_BEFORE = (os.makedirs, socket.socket.__init__)
S = G.load_server()
import llm_common  # noqa: E402  (on sys.path after load_server)
import llm_cache  # noqa: E402
ORIG = {"remote": S._remote_json, "provider": S.CFG.get("llm_provider"), "lt": S.grammar.correct, "cget": llm_cache.get, "cput": llm_cache.put}
cases = G.load_cases()
G.STATE["socket_probe"] = None
with G.no_network():
    docs = G.build(cases)
check("in-process build inside the guard: the engine call saw socket creation fail", G.STATE["socket_probe"] is True, G.STATE["socket_probe"])
G.STATE["socket_probe"] = None
G.build([c for c in cases if c["kind"] == "fix"][:1])   # one engine call, guard OFF
selfcheck("the same build with the guard OFF reports probe=False (the probe can tell the difference)", G.STATE["socket_probe"] is False, G.STATE["socket_probe"])
check("build outside main(): the guard is not left on and the server hooks are restored",
      (os.makedirs, socket.socket.__init__) == STATE_BEFORE and S._remote_json is ORIG["remote"] and S.CFG.get("llm_provider") == ORIG["provider"]
      and S.grammar.correct is ORIG["lt"] and llm_cache.get is ORIG["cget"] and llm_cache.put is ORIG["cput"])

# a server call that tries the network while the guard is on must fail loudly (the generator would exit 2 / crash, not hang)
with G.no_network():
    try:
        import requests
        requests.get("http://127.0.0.1:9/", timeout=1)
        reached = True
    except Exception:
        reached = False
selfcheck("a real HTTP attempt inside the guard fails", reached is False)

# ================================================================== PI2a-3: sizes and kinds
print("== PI2a-3 case counts and kinds")
chat, fix, fb, judge = load("chat.json"), load("fix.json"), load("feedback.json"), load("judge.json")
ko, hist, ques = load("ko_text.json"), load("clean_hist.json"), load("question.json")
check("chat >= 40", len(chat) >= 40, len(chat))
check("chat: stages 1,2,3,4 all used", {c["req"].get("stage") for c in chat} >= {1, 2, 3, 4})
scen = {json.dumps(c["req"].get("scenario"), sort_keys=True) for c in chat}
check("chat: >= 6 scenario variants (generic month / persona only / scene only / empty / none ...)", len(scen) >= 6, len(scen))


def last_user(c):
    for call in c["engine"][:1]:
        return call["messages"][-1]["content"]
    return ""


check("chat: last turn is a question (note 'asking you something') in >= 5 cases",
      sum(1 for c in chat if "is asking you something" in last_user(c)) >= 5)
check("chat: last turn is not a question ('Reply in character') in >= 5 cases",
      sum(1 for c in chat if "Reply in character: first respond directly" in last_user(c)) >= 5)
check("chat: empty history", any(c["req"]["history"] == [] for c in chat))
check("chat: history starting with ai", any(c["req"]["history"] and c["req"]["history"][0]["role"] == "ai" for c in chat))
check("chat: history longer than 24 (cut to 24 in the prompt)", any(len(c["req"]["history"]) > 24 for c in chat))
check("chat: a retried answer (attempts counted) and an ApiError answer exist",
      any(c["expect"]["attempts"] >= 3 for c in chat) and any("error" in c["expect"] for c in chat))
check("fix >= 30", len(fix) >= 30, len(fix))
check("fix: nothing to fix, a fix, Hangul-in-fix retry, ko_ok failure -> default text, two engine calls",
      any(c["expect"].get("result", {}).get("fix") == "" and c["expect"]["attempts"] == 1 for c in fix)
      and any(c["expect"].get("result", {}).get("fix") not in ("", None) for c in fix)
      and any(any(re.search("[가-힣]", e.get("reply", {}).get("fix", "")) for e in c["engine"]) and c["expect"]["attempts"] == 2 for c in fix)
      and any(c["expect"].get("result", {}).get("fix_ko") == "더 자연스럽게 고친 문장이에요." for c in fix)
      and any(c["expect"]["attempts"] == 2 for c in fix))
check("feedback >= 20", len(fb) >= 20, len(fb))
check("judge >= 20", len(judge) >= 20, len(judge))
check("judge: a verified quote, and an AI 'done' with a made-up quote that was refused",
      any(g["done"] for c in judge for g in c["expect"].get("result", {}).get("goals", []))
      and any(c["engine"] and any(x.get("done") is True and x.get("evidence") for x in c["engine"][0]["reply"].get("goals", []) if isinstance(x, dict))
              and not all(g["done"] for g in c["expect"].get("result", {}).get("goals", [{"done": False}])) for c in judge))
strings = {c["req"]["text"] for c in ko}
check("ko_ok / scrub_ko >= 60 distinct strings", len(strings) >= 60, len(strings))
check("ko strings include Chinese, Cyrillic and Korean-mixed text",
      any(re.search("[一-鿿]", s) for s in strings) and any(re.search("[Ѐ-ӿ]", s) for s in strings) and any(re.search("[가-힣]", s) for s in strings))
check("ko results: scrubbed text differs from the input for >= 15 strings", sum(1 for c in ko if c["expect"]["scrub_ko"] != c["req"]["text"]) >= 15)
check("clean_hist >= 15", len(hist) >= 15, len(hist))
check("looks_like_question >= 30 with both answers", len(ques) >= 30 and any(c["expect"]["result"] for c in ques) and any(not c["expect"]["result"] for c in ques))
for fname, mn in (("norm_text.json", 25), ("extract_json.json", 20), ("prompts.json", 20), ("api_call.json", 15)):
    check("%s has >= %d cases" % (fname, mn), len(load(fname)) >= mn, len(load(fname)))
check("every engine record has messages, schema, temperature, num_predict, and attempts == number of engine records",
      all(all(k in e for k in ("messages", "schema", "temperature", "num_predict")) and "attempts" in c["expect"] and c["expect"]["attempts"] == len(c["engine"])
          for f in ("chat.json", "fix.json", "feedback.json", "judge.json") for c in load(f) for e in c["engine"]))
check("every chat result has the server's seven keys", all(set(c["expect"]["result"]) == {"reply", "reading", "pron", "ko", "fix", "fix_ko", "suggest"}
                                                           for c in chat if "result" in c["expect"]))
check("no ja in chat / fix / feedback (English only on the phone): reading and pron are always empty",
      all(c["req"].get("lang") != "ja" for c in chat + fix + fb) and all(c["expect"]["result"]["reading"] == "" and c["expect"]["result"]["pron"] == "" for c in chat if "result" in c["expect"]))

# ================================================================== the files are exactly what the generator writes (and it is deterministic)
print("== files and determinism")
docs2 = G.build(cases)
check("two builds give the same data (nothing depends on the clock, the order or a cache)", docs == docs2)
tmp = tempfile.mkdtemp(prefix="hoehwa_aigolden_test_")
try:
    out_dir = os.path.join(tmp, "out")
    G.write_files(docs, out_dir)
    same = all(open(os.path.join(out_dir, f), "rb").read() == open(os.path.join(GOLDEN, f), "rb").read() for f in docs)
    check("the files in the repository are byte-identical to a fresh write", same)
    check("every case name of the cases file appears once in the golden files",
          sorted(c["case"] for c in cases) == sorted(r["case"] for f in docs for r in docs[f]["cases"]))
    check("compare() on a fresh copy reports nothing", G.compare(docs, out_dir) == [])

    # ---- wrong files: each damage must be named
    d1 = os.path.join(tmp, "d1")
    shutil.copytree(out_dir, d1)
    p = os.path.join(d1, "fix.json")
    doc = json.load(open(p, encoding="utf-8"))
    doc["cases"][3]["expect"]["result"]["fix"] += " x"
    json.dump(doc, open(p, "w", encoding="utf-8"), ensure_ascii=False)
    lines = G.compare(docs, d1)
    selfcheck("an edited expected value -> GOLDEN_DRIFT <that case> only", lines == ["GOLDEN_DRIFT " + doc["cases"][3]["case"]], lines)
    os.remove(os.path.join(d1, "judge.json"))
    open(os.path.join(d1, "chat.json"), "w", encoding="utf-8").write("{ broken json")
    open(os.path.join(d1, "stale.json"), "w", encoding="utf-8").write("{}")
    lines = G.compare(docs, d1)
    selfcheck("a deleted file, a broken JSON file and a stale file are named", "GOLDEN_MISSING judge.json" in lines and "GOLDEN_MISSING chat.json" in lines
              and "GOLDEN_EXTRA stale.json" in lines, lines)
    d2 = os.path.join(tmp, "d2")
    shutil.copytree(out_dir, d2)
    p = os.path.join(d2, "prompts.json")
    doc = json.load(open(p, encoding="utf-8"))
    removed = doc["cases"].pop()["case"]
    doc["cases"].append(dict(doc["cases"][0], case="invented_case"))
    json.dump(doc, open(p, "w", encoding="utf-8"), ensure_ascii=False)
    lines = G.compare(docs, d2)
    selfcheck("a removed case and an invented case are both named", "GOLDEN_DRIFT " + removed in lines and "GOLDEN_DRIFT invented_case" in lines, lines)

    # ---- bad cases files exit 2 (GoldenError), they do not pass
    bad = []
    for label, text in (("broken json", "{ nope"), ("no cases", json.dumps({"cases": []})),
                        ("duplicate name", json.dumps({"cases": [{"case": "a", "kind": "question", "req": {"text": "x", "lang": "en"}}] * 2})),
                        ("unknown kind", json.dumps({"cases": [{"case": "a", "kind": "zzz", "req": {}}]})),
                        ("missing req", json.dumps({"cases": [{"case": "a", "kind": "chat"}]}))):
        pth = os.path.join(tmp, "bad.json")
        open(pth, "w", encoding="utf-8").write(text)
        try:
            G.load_cases(pth)
            bad.append(label)
        except G.GoldenError:
            pass
    selfcheck("broken / empty / duplicate / unknown-kind / missing-req cases files are refused", bad == [], bad)
    short = {"case": "short", "kind": "chat", "req": {"lang": "en", "stage": 1, "month": 1, "week": 1, "scenario": {}, "history": [{"role": "me", "text": "Hi"}]},
             "script": [{"reply": {"reply": "Hello!", "reading": "", "ko": "안녕하세요!", "suggest": ["a", "b"]}}]}
    try:
        G.build([short])   # the learner spoke, so the server also asks for a correction: the script is one step short
        got = "no error"
    except G.GoldenError as e:
        got = "GoldenError"
    selfcheck("a script with too few steps stops the generator", got == "GoldenError", got)
    longer = dict(short, case="long", req=dict(short["req"], skip_fix=True), script=short["script"] + [{"reply": {"fix": "", "fix_ko": ""}}])
    try:
        G.build([longer])
        got = "no error"
    except G.GoldenError:
        got = "GoldenError"
    selfcheck("a script with unused steps stops the generator", got == "GoldenError", got)
finally:
    shutil.rmtree(tmp, ignore_errors=True)

# ================================================================== PI2a-5: drift (the server code is changed in memory)
print("== PI2a-5 drift detection")
rc, out = check_inproc()
check("baseline: --check in this process exits 0 before any change", rc == 0, out[-200:])

orig_rules = S.rules_text
with patched(S, "rules_text", lambda *a, **k: orig_rules(*a, **k).replace("Rules:", "Rulez:", 1)):
    rc, out = check_inproc()
selfcheck("rules_text changed by ONE letter ('Rules:' -> 'Rulez:') -> exit 1", rc == 1, rc)
selfcheck("  ... and GOLDEN_DRIFT names a chat case and a rules case", "GOLDEN_DRIFT chat_open_s1_cafe" in out and "GOLDEN_DRIFT rules_01" in out, out[:300])
selfcheck("  ... and cases that do not use rules_text are not named", "GOLDEN_DRIFT fix_basic" not in out and "GOLDEN_DRIFT ko_001" not in out and "GOLDEN_FAIL" in out)
rc, out = check_inproc()
check("after the change is undone --check exits 0 again", rc == 0, out[-200:])

# the same, as a real process: its EXIT CODE is 1 and the line is printed
code = ("import sys; sys.path.insert(0, %r); import make_ai_golden as g; S = g.load_server(); o = S.rules_text; "
        "S.rules_text = lambda *a, **k: o(*a, **k).replace('Rules:', 'Rulez:', 1); sys.exit(g.main(['--check']))" % HERE)
rc, out, err = run_py([], code)
selfcheck("process exit code 1 and 'GOLDEN_DRIFT chat_open_s1_cafe' on stdout (rules_text changed in memory)", rc == 1 and "GOLDEN_DRIFT chat_open_s1_cafe" in out, "rc=%s %s" % (rc, (out + err)[:200]))

LV = S.LEVEL["en"][2]
S.LEVEL["en"][2] = LV.replace("B1.", "B2.", 1)
try:
    rc, out = check_inproc()
finally:
    S.LEVEL["en"][2] = LV
selfcheck("LEVEL text changed -> exit 1, a stage-2 chat case drifts", rc == 1 and "GOLDEN_DRIFT chat_open_s2_cafe" in out, out[:200])

orig_ko = S.ko_ok
with patched(S, "ko_ok", lambda *a, **k: True):
    rc, out = check_inproc()
selfcheck("ko_ok always True -> exit 1 (ko, chat retry, fix retry cases drift)", rc == 1 and "GOLDEN_DRIFT ko_009" in out and "GOLDEN_DRIFT chat_retry_ko_chinese" in out, out[:200])

orig_q = S.looks_like_question
with patched(S, "looks_like_question", lambda t, lang: not orig_q(t, lang)):
    rc, out = check_inproc()
selfcheck("looks_like_question inverted -> exit 1", rc == 1 and "GOLDEN_DRIFT question_en_01" in out, out[:200])

orig_ch = S.clean_hist
with patched(S, "clean_hist", lambda h, limit=24: orig_ch(h, 23 if limit == 24 else limit)):
    rc, out = check_inproc()
selfcheck("clean_hist keeps 23 instead of 24 -> exit 1", rc == 1 and "GOLDEN_DRIFT clean_hist_limit_24_default" in out and "GOLDEN_DRIFT chat_hist_31_turns_cut_to_24" in out, out[:200])

orig_note = S.STRICT_JSON_NOTE
with patched(S, "STRICT_JSON_NOTE", orig_note.replace("ONLY", "only", 1)):
    rc, out = check_inproc()
selfcheck("STRICT_JSON_NOTE changed -> exit 1 (format-error retry cases)", rc == 1 and "GOLDEN_DRIFT chat_format_error_then_ok" in out, out[:200])

import missions  # noqa: E402
orig_jm = missions._judge_messages
with patched(missions, "_judge_messages", lambda *a, **k: [dict(m, content=m["content"].replace("LEARNER", "LEARNEr", 1)) for m in orig_jm(*a, **k)]):
    rc, out = check_inproc()
selfcheck("judge prompt changed -> exit 1", rc == 1 and "GOLDEN_DRIFT judge_all_quoted" in out, out[:200])

orig_q2 = missions._quoted_in
with patched(missions, "_quoted_in", lambda ev, me, lang="en": ev.strip() or None):
    rc, out = check_inproc()
selfcheck("judge quote check loosened (any quote accepted) -> exit 1", rc == 1 and "GOLDEN_DRIFT judge_evidence_not_in_learner_text" in out, out[:200])

orig_scrub = S.scrub_ko
with patched(S, "scrub_ko", lambda t, lang="en": t):
    rc, out = check_inproc()
selfcheck("scrub_ko does nothing -> exit 1", rc == 1 and "GOLDEN_DRIFT ko_009" in out, out[:200])

orig_ej = llm_common.extract_json
with patched(llm_common, "extract_json", lambda t: {"x": 1} if "```" in t else orig_ej(t)):
    rc, out = check_inproc()
selfcheck("extract_json changed -> exit 1 (extract_json and api cases)", rc == 1 and "GOLDEN_DRIFT extract_json_03" in out and "GOLDEN_DRIFT api_content_fenced" in out, out[:200])

orig_nt = S.norm_text
with patched(S, "norm_text", lambda s, lang: orig_nt(s, lang).upper()):
    rc, out = check_inproc()
selfcheck("norm_text changed -> exit 1", rc == 1 and "GOLDEN_DRIFT norm_en_01" in out, out[:200])

import llm_api  # noqa: E402
orig_settings = llm_api.settings
with patched(llm_api, "settings", lambda cfg: dict(orig_settings(cfg), model="other-model")):
    rc, out = check_inproc()
selfcheck("API request body changed (model) -> exit 1", rc == 1 and "GOLDEN_DRIFT api_ok_plain" in out, out[:200])

rc, out = check_inproc()
check("all changes undone: --check exits 0 again", rc == 0, out[-200:])

# ================================================================== PI2a-6: the two curriculum.json files
print("== PI2a-6 curriculum.json")


def curriculum_same(a, b):
    with open(a, "rb") as fa, open(b, "rb") as fb:
        same = fa.read() == fb.read()
    if not same:
        print("GOLDEN_CURRICULUM_DIFF %s %s" % (a, b))
    return same


check("backend\\curriculum.json == godot\\data\\curriculum.json (else GOLDEN_CURRICULUM_DIFF)",
      curriculum_same(os.path.join(BACKEND, "curriculum.json"), os.path.join(ROOT, "godot", "data", "curriculum.json")))
tmp = tempfile.mkdtemp(prefix="hoehwa_aigolden_cur_")
try:
    other = os.path.join(tmp, "curriculum.json")
    raw = open(os.path.join(BACKEND, "curriculum.json"), "rb").read()
    open(other, "wb").write(raw.replace(b"\xea\xb0\x80", b"\xeb\x82\x98", 1) if b"\xea\xb0\x80" in raw else raw + b" ")
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        diff = curriculum_same(os.path.join(BACKEND, "curriculum.json"), other)
    selfcheck("a changed copy is reported as GOLDEN_CURRICULUM_DIFF", diff is False and "GOLDEN_CURRICULUM_DIFF" in buf.getvalue())
finally:
    shutil.rmtree(tmp, ignore_errors=True)

# ================================================================== X-1 / X-2 and PI2a-7 (what the new files contain)
print("== X-1 X-2 PI2a-7")
KEY_RE = re.compile(r"(^|[^A-Za-z0-9_])sk-(ant-|proj-)?[A-Za-z0-9_-]{20,}|AIza[0-9A-Za-z_-]{30,}|gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}"
                    "|AKIA[0-9A-Z]{16}|xox[baprs]-[A-Za-z0-9-]{10,}|-----BEGIN " + "[A-Z ]*PRIVATE KEY-----")
owned = [GEN, CASES, os.path.join(HERE, "test_make_ai_golden.py")] + [os.path.join(GOLDEN, f) for f in sorted(os.listdir(GOLDEN))]
hits = [os.path.basename(p) for p in owned if KEY_RE.search(open(p, encoding="utf-8").read())]
check("X-2 key regex: 0 matches in the generator, the tests, the cases file and the golden files", hits == [], hits)
selfcheck("X-2 regex does catch a key-shaped string (built at run time, never written to a file)", KEY_RE.search("x " + "sk-" + "a1B2" * 6) is not None
          and KEY_RE.search("AIza" + "x" * 34) is not None)
mark = "FAKEKEY_" + "ZZ_"
check("X-1 markers (fake key / user-text marker) appear in no new file", not any(mark in open(p, encoding="utf-8").read() or "ZZ_MARK_" + "9731" in open(p, encoding="utf-8").read() for p in owned))
check("PI2a-7 no new file under backend\\tools\\", not os.path.exists(os.path.join(BACKEND, "tools", "make_ai_golden.py"))
      and not any(k.replace("\\", "/").startswith("tools/") and k not in BACKEND_BEFORE for k in tree_hashes(BACKEND)))

# ================================================================== PI2a-4 (second half): sha256 before / after
print("== PI2a-4 backend sha256 before and after")
after = tree_hashes(BACKEND)
after_py = {k: v for k, v in after.items() if k.endswith(".py") and os.sep not in k}
check("backend\\*.py sha256 identical before / after (%d files)" % len(after_py), after_py == BACKEND_PY_BEFORE and len(after_py) > 20, len(after_py))
check("backend\\ whole tree (files and folders, incl. cache, data, content) identical before / after (%d entries)" % len(after), after == BACKEND_BEFORE)
check("no backend\\cache, backend\\data, backend\\logs, __pycache__ were created", not any(k.split(os.sep)[0] in ("cache", "data", "logs", "models") or "__pycache__" in k for k in after if k not in BACKEND_BEFORE))
tmp = tempfile.mkdtemp(prefix="hoehwa_aigolden_h_")
try:
    with open(os.path.join(tmp, "x.py"), "wb") as fh:
        fh.write(b"a")
    h1 = tree_hashes(tmp)
    with open(os.path.join(tmp, "x.py"), "ab") as fh:
        fh.write(b"b")
    h2 = tree_hashes(tmp)
    os.makedirs(os.path.join(tmp, "newdir"))
    h3 = tree_hashes(tmp)
finally:
    shutil.rmtree(tmp, ignore_errors=True)
selfcheck("the hash comparison notices a changed file and a new folder (temp copy)", h1 != h2 and h2 != h3)

passed = sum(1 for _, ok in results if ok)
failed = len(results) - passed
print("\n%d passed, %d failed" % (passed, failed))
sys.exit(1 if failed else 0)
