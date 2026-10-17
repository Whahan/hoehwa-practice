# -*- coding: utf-8 -*-
"""Tests the mission API (/missions, /missions/check, /missions/judge, backend/missions.py) and lints content/missions.json.

Usage (a RUNNING test server that has the missions router mounted):
  .venv\\Scripts\\python.exe test_missions.py --base http://127.0.0.1:8811
Content check only (no server):
  .venv\\Scripts\\python.exe test_missions.py --lint [--content <path to a missions.json>] [--full]

Options:
  --base URL     required for the live tests (the app server on port 8770 is refused)
  --lint         only lint the content file
  --content P    lint this file instead of content/missions.json. For the live tests the server must have been started
                 with the same content (environment variable HOEHWA_CONTENT_DIR=<folder that holds missions.json>)
  --full         also require the final content set: the 8 missions of the design, each with its stage
  --no-extra     skip the in-process checks (fake AI for /missions/judge, broken content files, ...); they print SKIP
  --ai           also call the real AI through /missions/judge (skipped by default: it needs a working AI engine)
Exit code 0 only if nothing FAILED and nothing is UNVERIFIED.
"""
import os
import re
import sys
import json
import time
import tempfile

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_CONTENT = os.path.join(HERE, "content", "missions.json")
HANGUL = re.compile(r"[가-힣]")
ID_RE = re.compile(r"^[a-z][a-z0-9_]{1,40}$")
FULL_SET = {"cafe_order": 1, "self_intro": 1, "hotel_checkin": 2, "ask_directions": 2, "restaurant": 2,
            "pharmacy_doctor": 3, "return_item": 3, "job_interview": 4}
SECRET_KEYS = {"match", "pos", "neg", "goal_en"}
BOMBS = ["a" * 300 + "!", "I'd like " * 40, "a " * 150, "i" * 300, "can i have " * 30, ("hello " * 60) + "x" + (" thank you" * 20)]

LINT = "--lint" in sys.argv
FULL = "--full" in sys.argv
NO_EXTRA = "--no-extra" in sys.argv
RUN_AI = "--ai" in sys.argv


def _opt(name):
    if name in sys.argv:
        i = sys.argv.index(name)
        if i + 1 < len(sys.argv):
            return sys.argv[i + 1]
    return None


def _require_base():
    base = _opt("--base")
    if base is None:
        if LINT:
            return None
        sys.exit("--base 가 필요해요 / --base is required. Start your own test server and pass --base http://127.0.0.1:8811")
    base = base.rstrip("/")
    if re.search(r":8770(/|$)", base) and "--allow-app-server" not in sys.argv:
        sys.exit("--base points at the app server (port 8770): refused. Use a test server, or add --allow-app-server.")
    return base


BASE = _require_base()
CONTENT = _opt("--content") or DEFAULT_CONTENT
if not os.path.isabs(CONTENT):
    CONTENT = os.path.abspath(CONTENT)

sys.path.insert(0, HERE)
import missions as M   # light: no models, no network

results = []


def check(name, cond, detail=""):
    results.append((name, "PASS" if cond else "FAIL"))
    print("  [%s] %s%s" % ("PASS" if cond else "FAIL", name, (" -- " + str(detail)) if detail != "" else ""))
    return bool(cond)


def unverified(name, why):
    results.append((name, "UNVERIFIED"))
    print("  [미검증] %s -- %s" % (name, why))


def skip(name, why):
    results.append((name, "SKIP"))
    print("  [SKIP] %s -- %s" % (name, why))


# ----------------------------------------------------------------------------------------------
# content lint (pure: data in, list of problems out)
# ----------------------------------------------------------------------------------------------
def _ne(v):
    return isinstance(v, str) and bool(v.strip())


def _compile_goal(g, errs, tag):
    """(any, all) lists of compiled patterns of a goal, or None after recording why not"""
    match = g.get("match")
    if not isinstance(match, dict):
        errs.append("%s: match가 객체가 아니에요" % tag)
        return None
    out = {}
    for key in ("any", "all"):
        pats = match.get(key, [])
        if not isinstance(pats, list) or not all(_ne(p) for p in pats):
            errs.append("%s: match.%s가 문자열 목록이 아니에요" % (tag, key))
            return None
        out[key] = pats
    if not out["any"] and not out["all"]:
        errs.append("%s: match.any 와 match.all 이 둘 다 비어 있어요" % tag)
        return None
    comp = {"any": [], "all": []}
    bad = False
    for key in ("any", "all"):
        for p in out[key]:
            why = M.unsafe_regex(p)
            if why:
                errs.append("%s: match.%s 패턴 %r -> %s" % (tag, key, p[:70], why))
                bad = True
            else:
                comp[key].append(re.compile(p, re.I))
    return None if bad else comp


def mission_errors(data, full=False):
    errs = []
    if not isinstance(data, dict):
        return ["최상위가 객체가 아니에요"]
    if data.get("version") != 1:
        errs.append("version이 1이 아니에요")
    ms = data.get("missions")
    if not isinstance(ms, list) or not ms:
        return errs + ["missions가 비어 있거나 목록이 아니에요"]
    seen = set()
    for i, m in enumerate(ms):
        if not isinstance(m, dict):
            errs.append("#%d: 미션이 객체가 아니에요" % i)
            continue
        mid = m.get("id")
        tag = "미션 %s" % (mid if isinstance(mid, str) else "#%d" % i)
        if not isinstance(mid, str) or not ID_RE.match(mid):
            errs.append("%s: id가 영소문자·숫자·_ 형식이 아니에요" % tag)
        elif mid in seen:
            errs.append("%s: id가 중복이에요" % tag)
        seen.add(mid)
        if m.get("lang") != "en":
            errs.append("%s: lang이 'en'이 아니에요" % tag)
        if not (isinstance(m.get("min_stage"), int) and not isinstance(m.get("min_stage"), bool) and 1 <= m["min_stage"] <= 4):
            errs.append("%s: min_stage가 1~4 정수가 아니에요" % tag)
        if not (isinstance(m.get("order"), int) and not isinstance(m.get("order"), bool)):
            errs.append("%s: order가 정수가 아니에요" % tag)
        for key in ("title_ko", "situation_ko"):
            if not (_ne(m.get(key)) and HANGUL.search(m[key])):
                errs.append("%s: %s에 한글이 없어요" % (tag, key))
        for key in ("persona", "scene"):
            if not _ne(m.get(key)):
                errs.append("%s: %s가 비어 있어요" % (tag, key))
        if not _ne(m.get("opening")):
            errs.append("%s: opening이 비어 있어요" % tag)
        elif HANGUL.search(m["opening"]):
            errs.append("%s: opening에 한글이 있어요" % tag)
        goals = m.get("goals")
        if not isinstance(goals, list) or not 3 <= len(goals) <= 5:
            errs.append("%s: 목표가 3~5개가 아니에요 (%s개)" % (tag, len(goals) if isinstance(goals, list) else "?"))
            goals = goals if isinstance(goals, list) else []
        mt = m.get("max_turns")
        if not (isinstance(mt, int) and not isinstance(mt, bool) and mt >= len(goals) + 3):
            errs.append("%s: max_turns(%r)가 목표 수 + 3 (%d) 이상이 아니에요" % (tag, mt, len(goals) + 3))
        gids, compiled = [], {}
        for j, g in enumerate(goals):
            if not isinstance(g, dict):
                errs.append("%s: goals[%d]가 객체가 아니에요" % (tag, j))
                continue
            gid = g.get("id")
            gtag = "%s/%s" % (tag, gid if isinstance(gid, str) else "goals[%d]" % j)
            if not isinstance(gid, str) or not ID_RE.match(gid):
                errs.append("%s: id가 영소문자·숫자·_ 형식이 아니에요" % gtag)
            elif gid in gids:
                errs.append("%s: 목표 id가 중복이에요" % gtag)
            gids.append(gid)
            if not (_ne(g.get("label_ko")) and HANGUL.search(g["label_ko"])):
                errs.append("%s: label_ko에 한글이 없어요" % gtag)
            if not _ne(g.get("goal_en")) or HANGUL.search(g.get("goal_en") or ""):
                errs.append("%s: goal_en이 비어 있거나 한글이 있어요" % gtag)
            if not _ne(g.get("hint_en")) or HANGUL.search(g.get("hint_en") or ""):
                errs.append("%s: hint_en이 비어 있거나 한글이 있어요" % gtag)
            comp = _compile_goal(g, errs, gtag)
            pos, neg = g.get("pos"), g.get("neg")
            if not (isinstance(pos, list) and len(pos) >= 3 and all(_ne(x) for x in pos)):
                errs.append("%s: pos가 문자열 3개 이상이 아니에요" % gtag)
                pos = []
            if not (isinstance(neg, list) and len(neg) >= 3 and all(_ne(x) for x in neg)):
                errs.append("%s: neg가 문자열 3개 이상이 아니에요" % gtag)
                neg = []
            if comp is None:
                continue
            cg = {"any": comp["any"], "all": comp["all"]}
            compiled[gid] = cg
            for s in pos:
                if not M.goal_matches(cg, M.normalize(s)):
                    errs.append("%s: pos %r 가 달성되지 않아요" % (gtag, s))
            for s in neg:
                if M.goal_matches(cg, M.normalize(s)):
                    errs.append("%s: neg %r 가 달성돼 버려요" % (gtag, s))
            if _ne(g.get("hint_en")) and not M.goal_matches(cg, M.normalize(g["hint_en"])):
                errs.append("%s: hint_en %r 자체가 이 목표를 달성하지 못해요" % (gtag, g["hint_en"]))
            slow = 0.0
            for b in BOMBS:
                t0 = time.perf_counter()
                M.goal_matches(cg, M.normalize(b))
                slow = max(slow, time.perf_counter() - t0)
            if slow > 0.05:
                errs.append("%s: 폭탄 입력에서 %.3f초 걸려요 (0.05초 초과)" % (gtag, slow))
        script = m.get("script")
        if not isinstance(script, list) or len(script) < len(goals):
            errs.append("%s: script가 목표 수(%d)보다 적어요" % (tag, len(goals)))
            script = script if isinstance(script, list) else []
        used = set()
        for j, s in enumerate(script):
            stag = "%s/script[%d]" % (tag, j)
            if not isinstance(s, dict):
                errs.append("%s: 객체가 아니에요" % stag)
                continue
            if not _ne(s.get("ai")) or HANGUL.search(s.get("ai") or ""):
                errs.append("%s: ai가 비어 있거나 한글이 있어요" % stag)
            if s.get("goal") not in gids:
                errs.append("%s: goal %r 가 이 미션의 목표 id가 아니에요" % (stag, s.get("goal")))
                continue
            used.add(s["goal"])
            if not _ne(s.get("model")):
                errs.append("%s: model이 비어 있어요" % stag)
            elif s["goal"] in compiled and not M.goal_matches(compiled[s["goal"]], M.normalize(s["model"])):
                errs.append("%s: model %r 가 자기 목표(%s)를 달성하지 못해요" % (stag, s["model"], s["goal"]))
        for gid in gids:
            if gid not in used and isinstance(gid, str):
                errs.append("%s: 목표 %s 에 해당하는 script 줄이 없어요 (대본 모드에서 달성 불가)" % (tag, gid))
    if full:
        ids = {m.get("id"): m.get("min_stage") for m in ms if isinstance(m, dict)}
        if set(ids) != set(FULL_SET):
            errs.append("--full: 미션 id가 설계의 8개와 달라요. 빠진 것 %s, 더 있는 것 %s" % (sorted(set(FULL_SET) - set(ids)), sorted(set(ids) - set(FULL_SET))))
        else:
            wrong = {k: ids[k] for k in FULL_SET if ids[k] != FULL_SET[k]}
            if wrong:
                errs.append("--full: min_stage가 설계와 달라요 %s (기대 %s)" % (wrong, {k: FULL_SET[k] for k in wrong}))
    return errs


def run_lint(path, full):
    print("\n== lint %s%s" % (path, " (--full)" if full else ""))
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
    except Exception as e:
        check("JSON을 읽을 수 있음", False, "%s: %s" % (type(e).__name__, str(e)[:150]))
        return None
    check("JSON을 읽을 수 있음", True)
    errs = mission_errors(data, full=full)
    n = len(data.get("missions", [])) if isinstance(data, dict) and isinstance(data.get("missions"), list) else 0
    check("스키마·정규식 안전·pos/neg·script (미션 %d개)" % n, not errs, "")
    for e in errs[:25]:
        print("      - " + e)
    if len(errs) > 25:
        print("      ... 외 %d건" % (len(errs) - 25))
    if not full and n < len(FULL_SET):
        print("  (미션 %d/%d개: 최종 8개 확인은 --full)" % (n, len(FULL_SET)))
    return data


def _mutated(data, fn):
    d = json.loads(json.dumps(data))
    fn(d["missions"][0])
    return d


def meta_lint_checks(good):
    """the linter must really FAIL on wrong content"""
    print("\n== lint 자체 검사 (일부러 틀린 내용)")
    if not good or mission_errors(good):
        unverified("lint 자체 검사", "기준이 될 올바른 내용을 읽지 못했거나 그 내용이 lint를 통과하지 못해요")
        return
    check("올바른 내용은 문제 0건", mission_errors(good) == [])
    g0 = lambda m: m["goals"][1]
    cases = [
        ("중첩 반복 (.+)+", lambda m: g0(m)["match"].__setitem__("any", ["(.+)+x"])),
        ("중첩 반복 (a+)+", lambda m: g0(m)["match"].__setitem__("any", ["\\b(a+)+\\b"])),
        ("중첩 반복 (.*)*", lambda m: g0(m)["match"].__setitem__("any", ["(.*)*z"])),
        ("반복 안의 선택 (a|aa)+", lambda m: g0(m)["match"].__setitem__("any", ["^(a|aa)+$"])),
        ("넓은 반복 3개", lambda m: g0(m)["match"].__setitem__("any", ["a.*b.*c.*d"])),
        ("컴파일 안 되는 정규식", lambda m: g0(m)["match"].__setitem__("any", ["(unclosed"])),
        ("any/all 둘 다 비어 있음", lambda m: g0(m)["match"].update({"any": [], "all": []})),
        ("pos 2개", lambda m: g0(m).__setitem__("pos", g0(m)["pos"][:2])),
        ("neg 2개", lambda m: g0(m).__setitem__("neg", g0(m)["neg"][:2])),
        ("pos가 달성 안 됨", lambda m: g0(m)["pos"].append("zzz qqq")),
        ("neg가 달성돼 버림", lambda m: g0(m)["neg"].append(g0(m)["pos"][0])),
        ("hint_en이 달성 안 됨", lambda m: g0(m).__setitem__("hint_en", "Banana")),
        ("script 목표 id 없음", lambda m: m["script"][0].__setitem__("goal", "nope")),
        ("script model이 목표 미달성", lambda m: m["script"][1].__setitem__("model", "Banana")),
        ("script가 목표 수보다 적음", lambda m: m.__setitem__("script", m["script"][:2])),
        ("max_turns가 작음", lambda m: m.__setitem__("max_turns", len(m["goals"]) + 2)),
        ("opening에 한글", lambda m: m.__setitem__("opening", "안녕하세요!")),
        ("목표 2개", lambda m: m.__setitem__("goals", m["goals"][:2])),
        ("목표 id 중복", lambda m: m["goals"][1].__setitem__("id", m["goals"][0]["id"])),
        ("label_ko에 한글 없음", lambda m: g0(m).__setitem__("label_ko", "order")),
        ("lang이 ja", lambda m: m.__setitem__("lang", "ja")),
    ]
    for name, fn in cases:
        check("틀린 내용을 잡음: " + name, mission_errors(_mutated(good, fn)) != [])
    d = json.loads(json.dumps(good))
    d["missions"].append(json.loads(json.dumps(d["missions"][0])))
    check("틀린 내용을 잡음: 미션 id 중복", mission_errors(d) != [])
    check("틀린 내용을 잡음: version", mission_errors({"version": 3, "missions": good["missions"]}) != [])
    check("틀린 내용을 잡음: 최상위가 목록", mission_errors([1]) != [])
    check("--full: 8개 미만이면 FAIL", mission_errors(good, full=True) != [] if len(good["missions"]) != 8 else True)


# ----------------------------------------------------------------------------------------------
# live tests
# ----------------------------------------------------------------------------------------------
HANGUL_ERR = lambda r: _is_korean_error(r)


def _is_korean_error(r):
    try:
        b = r.json()
    except Exception:
        return False
    return isinstance(b, dict) and set(b) == {"error"} and isinstance(b["error"], str) and bool(HANGUL.search(b["error"]))


def _walk_keys(o, found):
    if isinstance(o, dict):
        for k, v in o.items():
            found.add(k)
            _walk_keys(v, found)
    elif isinstance(o, list):
        for v in o:
            _walk_keys(v, found)


def live_tests(data):
    import requests
    S = requests.Session()
    ms = data["missions"] if isinstance(data, dict) and isinstance(data.get("missions"), list) else []

    def get(path, **params):
        return S.get(BASE + path, params=params, timeout=60)

    def post(path, body=None, **kw):
        return S.post(BASE + path, json=body, timeout=60, **kw)

    print("\n== GET /missions")
    r = get("/missions", lang="en")
    d = r.json() if r.status_code == 200 else {}
    lst = d.get("missions", [])
    check("lang=en -> 200, unsupported:false, 미션 수가 콘텐츠와 같음", r.status_code == 200 and d.get("unsupported") is False and len(lst) == len(ms), "%s %d개 / 콘텐츠 %d개" % (r.status_code, len(lst), len(ms)))
    keys = set()
    _walk_keys(d, keys)
    for word in ('"match"', '"pos"', '"neg"', '"goal_en"'):
        check("응답 본문에 %s 글자가 없음" % word, word not in r.text)
    check("응답의 어떤 객체 키도 match/pos/neg/goal_en 이 아님", not (keys & SECRET_KEYS), keys & SECRET_KEYS)
    order = sorted(ms, key=lambda m: (m["order"], m["id"]))
    check("order 순서로 정렬됨", [m["id"] for m in lst] == [m["id"] for m in order])
    shape_ok = True
    scene_ok = True
    for got, want in zip(lst, order):
        shape_ok &= set(got) == {"id", "title_ko", "situation_ko", "min_stage", "max_turns", "opening", "goals", "scenario", "script"} \
            and [g["id"] for g in got["goals"]] == [g["id"] for g in want["goals"]] \
            and all(set(g) == {"id", "label_ko", "hint_en"} for g in got["goals"]) and got["script"] == want["script"] \
            and got["scenario"]["id"] == "mission:" + want["id"] and got["scenario"]["title"] == want["title_ko"] \
            and got["scenario"]["persona"] == want["persona"] and got["opening"] == want["opening"]
        sc = got["scenario"]["scene"]
        scene_ok &= sc.startswith(want["scene"].strip()) and "Your opening line was:" in sc and want["opening"] in sc \
            and "never reveal them" in sc and all(g["goal_en"] in sc for g in want["goals"])
    check("각 미션의 필드·목표 id·script·scenario 모양", shape_ok and bool(lst))
    check("scenario.scene 에 'Your opening line was:' + 첫 마디 + 숨은 목표 설명", scene_ok and bool(lst))
    for s in (1, 2, 3, 4):
        want_ids = [m["id"] for m in order if m["min_stage"] <= s]
        got_ids = [m["id"] for m in get("/missions", lang="en", stage=s).json().get("missions", [])]
        check("stage=%d 필터: min_stage <= %d 만" % (s, s), got_ids == want_ids, "%s / 기대 %s" % (got_ids, want_ids))
    r = get("/missions", lang="en", stage=-5)
    check("stage=-5 은 1단계로 보정", [m["id"] for m in r.json().get("missions", [])] == [m["id"] for m in order if m["min_stage"] <= 1])
    r = get("/missions", lang="en", stage="abc")
    check("stage=abc 는 필터 없이 전부", r.status_code == 200 and len(r.json().get("missions", [])) == len(ms))
    r = get("/missions", lang="ja")
    d = r.json()
    check("lang=ja -> 200, unsupported:true, missions [], message(한글)", r.status_code == 200 and d.get("unsupported") is True and d.get("missions") == []
          and d.get("lang") == "ja" and bool(HANGUL.search(d.get("message", ""))), r.text[:150])
    r = get("/missions", lang="xx")
    check("lang=xx -> 400 + 한글 error", r.status_code == 400 and HANGUL_ERR(r), r.text[:100])
    r = get("/missions", lang="")
    check("lang 비어 있음 -> 400", r.status_code == 400 and HANGUL_ERR(r))
    check("lang 생략 -> 영어 목록", len(get("/missions").json().get("missions", [])) == len(ms))

    print("\n== POST /missions/check : pos 는 달성, neg 는 미달성 (콘텐츠 전부, 실제 HTTP)")
    total = bad = 0
    worst = 0.0
    problems = []
    for m in ms:
        for g in m["goals"]:
            for kind, texts in (("pos", g["pos"]), ("neg", g["neg"])):
                for t in texts:
                    t0 = time.perf_counter()
                    r = post("/missions/check", {"lang": "en", "mission_id": m["id"], "text": t, "done": []})
                    worst = max(worst, time.perf_counter() - t0)
                    total += 1
                    got = {x["id"]: x for x in r.json().get("goals", [])}.get(g["id"]) if r.status_code == 200 else None
                    want = kind == "pos"
                    if got is None or got["done"] != want or got["new"] != want:
                        bad += 1
                        problems.append("%s/%s %s %r" % (m["id"], g["id"], kind, t))
    check("pos/neg %d건 모두 기대대로 (미션 %d개)" % (total, len(ms)), bad == 0 and total > 0, problems[:5])
    print("  (가장 느린 응답 %.0f ms)" % (worst * 1000))

    print("\n== done 누적 / new / all_done")
    if ms:
        m = ms[0]
        done = []
        ok_seq = True
        detail = []
        for k, g in enumerate(m["goals"]):
            r = post("/missions/check", {"lang": "en", "mission_id": m["id"], "text": g["pos"][0], "done": done})
            b = r.json() if r.status_code == 200 else {}
            gmap = {x["id"]: x for x in b.get("goals", [])}
            this = gmap.get(g["id"], {})
            prior_ok = all(gmap.get(p, {}).get("done") and not gmap.get(p, {}).get("new") for p in done)
            # pos[0] of this goal may also reach other goals that are not done yet; those are "new" too
            new_ok = g["id"] in b.get("new", []) and set(b.get("new", [])) == {i for i, x in gmap.items() if x["new"]}
            step_ok = this.get("done") and this.get("new") and prior_ok and new_ok
            ok_seq &= bool(step_ok)
            detail.append((g["id"], bool(step_ok)))
            done = [i for i, x in gmap.items() if x["done"]]
        check("목표를 하나씩 보내며 done 을 되돌려 줘도 누적, 이미 한 것은 new:false", ok_seq, detail)
        r = post("/missions/check", {"lang": "en", "mission_id": m["id"], "text": m["goals"][0]["pos"][0], "done": [g["id"] for g in m["goals"]]})
        b = r.json()
        check("전부 done 을 보내면 all_done:true, new []", b.get("all_done") is True and b.get("new") == [] and all(x["done"] and not x["new"] for x in b["goals"]), r.text[:150])
        # reach every goal with its own pos[0] in one go via the done list
        r = post("/missions/check", {"lang": "en", "mission_id": m["id"], "text": m["goals"][-1]["pos"][0], "done": [g["id"] for g in m["goals"][:-1]]})
        b = r.json()
        last_id = m["goals"][-1]["id"]
        check("마지막 목표를 달성하면 all_done:true 이고 new 에 그 목표가 있음", b.get("all_done") is True and last_id in b.get("new", []), r.text[:150])
        r = post("/missions/check", {"lang": "en", "mission_id": m["id"], "text": "zzz", "done": []})
        b = r.json()
        check("아무것도 달성 못 하면 all_done:false, new []", b.get("all_done") is False and b.get("new") == [] and [x["id"] for x in b["goals"]] == [g["id"] for g in m["goals"]]
              and set(b) == {"mission_id", "goals", "new", "all_done"})

    print("\n== 틀린 입력")
    mid = ms[0]["id"] if ms else "cafe_order"
    good_body = {"lang": "en", "mission_id": mid, "text": "hello", "done": []}

    def expect(name, r, status, korean=True, under=None, elapsed=None):
        ok = r.status_code == status and (not korean or _is_korean_error(r)) and (under is None or (elapsed is not None and elapsed < under))
        check(name, ok, "HTTP %s %s%s" % (r.status_code, "" if ok else r.text[:100], "" if elapsed is None else " %.0f ms" % (elapsed * 1000)))

    expect("빈 text -> 400 + 한글", post("/missions/check", dict(good_body, text="")), 400)
    expect("공백만 있는 text -> 400", post("/missions/check", dict(good_body, text="  \t\n ")), 400)
    expect("알 수 없는 mission_id -> 404", post("/missions/check", dict(good_body, mission_id="nope_zzz")), 404)
    expect("mission_id 빈 문자열 -> 404", post("/missions/check", dict(good_body, mission_id="")), 404)
    expect("lang=xx -> 400", post("/missions/check", dict(good_body, lang="xx")), 400)
    expect("lang=ja -> 400", post("/missions/check", dict(good_body, lang="ja")), 400)
    r = post("/missions/check", dict(good_body, text="zzz qqq", done=["zzz", "nope", 5, None, {"a": 1}, ["x"]]))
    check("done 에 모르는 id·숫자·null·객체 -> 200, 무시", r.status_code == 200 and not any(x["done"] for x in r.json()["goals"]), r.text[:120])
    r = post("/missions/check", dict(good_body, text="zzz qqq", done=["zzz%d" % i for i in range(1000)]))
    check("done 에 모르는 id 1000개 -> 200, 무시", r.status_code == 200 and not any(x["done"] for x in r.json()["goals"]), "HTTP %s" % r.status_code)
    r = post("/missions/check", dict(good_body, done=[g["id"] for g in ms[0]["goals"]] * 300)) if ms else None
    check("done 에 진짜 id 를 1000+번 반복 -> 200", r is not None and r.status_code == 200 and r.json()["all_done"] is True, "" if r is None else "HTTP %s" % r.status_code)
    r = post("/missions/check", dict(good_body, done=None))
    check("done:null -> 200", r.status_code == 200)
    body = {k: v for k, v in good_body.items() if k != "done"}
    check("done 생략 -> 200", post("/missions/check", body).status_code == 200)
    r = post("/missions/check", dict(good_body, text="저는 라떼 한 잔 주세요. 감사합니다. 안녕하세요"))
    check("한글만 있는 문장 -> 200, 달성 0", r.status_code == 200 and r.json()["new"] == [] and not any(x["done"] for x in r.json()["goals"]), r.text[:100])
    r = post("/missions/check", dict(good_body, text="😀🙂 \u0000 ‮ ✓"))
    check("이모지·NUL·제어문자만 -> 200, 달성 0", r.status_code == 200 and r.json()["new"] == [])
    t0 = time.perf_counter()
    r = post("/missions/check", dict(good_body, text="Hello there. " * 400))
    dt = time.perf_counter() - t0
    check("5000자 -> 200 + 1초 미만 (300자에서 자름)", r.status_code == 200 and dt < 1.0, "HTTP %s %.0f ms" % (r.status_code, dt * 1000))
    r2 = post("/missions/check", dict(good_body, text=("x " * 160) + "hello"))
    check("300자를 넘은 뒤의 내용은 보지 않음 (끝의 hello 무시)", r2.status_code == 200 and not r2.json()["new"], r2.text[:100])
    for label, text in (("a*300 + '!'", "a" * 300 + "!"), ("'I'd like ' * 40", "I'd like " * 40), ("'a ' * 2500", "a " * 2500), ("'can i have ' * 30", "can i have " * 30)):
        t0 = time.perf_counter()
        r = post("/missions/check", dict(good_body, text=text))
        dt = time.perf_counter() - t0
        check("정규식 폭탄 %s -> 200 + 0.5초 미만" % label, r.status_code == 200 and dt < 0.5, "HTTP %s %.0f ms" % (r.status_code, dt * 1000))
    r = S.post(BASE + "/missions/check", data="{ this is not json", headers={"Content-Type": "application/json"}, timeout=60)
    expect("깨진 JSON 본문 -> 422 + 한글", r, 422)
    r = S.post(BASE + "/missions/check", data="", headers={"Content-Type": "application/json"}, timeout=60)
    expect("빈 본문 -> 422", r, 422)
    for miss in ("lang", "mission_id", "text"):
        expect("필드 %s 누락 -> 422 + 한글" % miss, post("/missions/check", {k: v for k, v in good_body.items() if k != miss}), 422)
    expect("text 가 숫자 -> 422", post("/missions/check", dict(good_body, text=5)), 422)
    expect("done 이 문자열 -> 422", post("/missions/check", dict(good_body, done="greet")), 422)
    expect("본문이 JSON 배열 -> 422", post("/missions/check", [1, 2]), 422)
    r = S.get(BASE + "/missions/check", timeout=60)
    check("GET /missions/check -> 405 (500 아님)", r.status_code == 405, "HTTP %s" % r.status_code)

    print("\n== POST /missions/judge (AI 없이 확인되는 부분)")
    jb = {"lang": "en", "mission_id": mid, "pending": [ms[0]["goals"][1]["id"] if ms else "x"], "history": [{"role": "me", "text": "hi"}]}
    expect("pending 이 비면 -> 400 + 한글 (AI 호출 전에 거절)", post("/missions/judge", dict(jb, pending=[])), 400)
    expect("pending 에 모르는 id 만 있으면 -> 400", post("/missions/judge", dict(jb, pending=["nope", 5])), 400)
    expect("알 수 없는 미션 -> 404", post("/missions/judge", dict(jb, mission_id="nope_zzz")), 404)
    expect("lang=xx -> 400", post("/missions/judge", dict(jb, lang="xx")), 400)
    expect("lang=ja -> 400", post("/missions/judge", dict(jb, lang="ja")), 400)
    expect("pending 누락 -> 422", post("/missions/judge", {k: v for k, v in jb.items() if k != "pending"}), 422)
    expect("깨진 JSON -> 422", S.post(BASE + "/missions/judge", data="{{", headers={"Content-Type": "application/json"}, timeout=60), 422)
    r = post("/missions/judge", dict(jb, history=[]))
    b = r.json() if r.status_code == 200 else {}
    check("내 발화가 없으면 AI 를 부르지 않고 전부 done:false", r.status_code == 200 and b.get("ai") is False and all(g["done"] is False for g in b["goals"]), r.text[:150])
    if RUN_AI and ms:
        g = ms[0]["goals"][1]
        said = g["pos"][0]
        hist = [{"role": "ai", "text": ms[0]["opening"]}, {"role": "me", "text": said}]
        t0 = time.perf_counter()
        r = post("/missions/judge", {"lang": "en", "mission_id": ms[0]["id"], "pending": [g["id"], ms[0]["goals"][-1]["id"]], "history": hist})
        dt = time.perf_counter() - t0
        if r.status_code in (502, 503, 504):
            check("실제 AI: 사용 불가면 502/503 + 한글 error", _is_korean_error(r), "HTTP %s %s" % (r.status_code, r.text[:100]))
        else:
            b = r.json() if r.status_code == 200 else {}
            ok = r.status_code == 200 and b.get("ai") is True and [x["id"] for x in b["goals"]] == [g["id"], ms[0]["goals"][-1]["id"]] \
                and all(x["done"] is False or (x["evidence"] and x["evidence"] in said) for x in b["goals"])
            check("실제 AI: 응답 모양, done:true 의 evidence 는 내 발화 안에 있음 (%.1f초)" % dt, ok, r.text[:200])
    else:
        skip("실제 AI 호출(/missions/judge)", "--ai 가 없어서 건너뜀")
        print("SKIP 1 (--ai)")


# ----------------------------------------------------------------------------------------------
# in-process checks: fake AI, broken / odd content files, normalisation, regex guard
# ----------------------------------------------------------------------------------------------
class FakeApiError(Exception):
    def __init__(self, msg, status=400, format_error=False):
        super().__init__(msg)
        self.msg, self.status, self.format_error = msg, status, format_error


def _fake_app():
    from fastapi import FastAPI, Request
    from fastapi.responses import JSONResponse
    from fastapi.exceptions import RequestValidationError
    app = FastAPI()

    @app.exception_handler(FakeApiError)
    async def _a(request: Request, exc: FakeApiError):
        return JSONResponse({"error": exc.msg}, status_code=exc.status)

    @app.exception_handler(RequestValidationError)
    async def _v(request: Request, exc: RequestValidationError):
        return JSONResponse({"error": "요청 형식이 올바르지 않아요."}, status_code=422)

    @app.exception_handler(Exception)
    async def _e(request: Request, exc: Exception):
        return JSONResponse({"error": "서버에서 예기치 않은 오류가 났어요."}, status_code=500)
    app.include_router(M.router)
    return app


def extra_tests(data):
    print("\n== 프로세스 안 검사 (가짜 AI, 이상한 콘텐츠 파일, 정규화, 정규식 방어)")
    import logging
    from fastapi.testclient import TestClient
    log = logging.getLogger("test_missions")
    log.setLevel(logging.CRITICAL)
    saved_dir = M.CONTENT_DIR
    saved_h = dict(M.H)
    try:
        ms = data["missions"] if isinstance(data, dict) else []
        mission = ms[0] if ms else None
        if mission is None:
            unverified("프로세스 안 검사", "콘텐츠를 읽지 못했어요")
            return

        # ---- normalisation
        n = M.normalize
        check("normalize: 소문자·’→'·구두점→공백·공백 합치기", n("  I’D   Like, a LATTE!! ") == "i'd like a latte")
        check("normalize: NFKC (전각 영문)", n("ＨＥＬＬＯ　ｗｏｒｌｄ") == "hello world")
        check("normalize: 한글만 -> 빈 문자열", n("안녕하세요 라떼") == "")
        check("normalize: 300자 상한", len(n("a" * 5000)) == 300 and len(n("ab " * 400)) <= 300)
        check("normalize: 문자열이 아니면 빈 문자열", n(None) == "" and n(5) == "")
        # ---- the regex guard
        for p, expect_bad in (("(.+)+", True), ("(.*)*", True), ("(a+)+", True), ("(a+)*b", True), ("(a|aa)+", True), ("(?:\\w+\\s?)+", True),
                              ("(x{2,})+", True), ("a.*b.*c.*d", True), ("(", True), ("", True), ("   ", True), ("a" * 400, True),
                              ("\\b(hi|hello)\\b", False), ("\\bi(?: am|'m) [a-z]+", False), ("(?:a|b)c", False), ("a.{0,40}b.{0,40}c", False),
                              ("\\b(nice|pleased) to meet you\\b", False), ("(?!x)[a-z]+", False)):
            check("unsafe_regex(%r) %s" % (p[:30], "거부" if expect_bad else "허용"), (M.unsafe_regex(p) is not None) == expect_bad, M.unsafe_regex(p))
        check("unsafe_regex: 문자열이 아니면 거부", M.unsafe_regex(None) is not None and M.unsafe_regex(5) is not None)

        # ---- content files: the server keeps running on odd files
        M.init(ApiError=FakeApiError, log=log)
        with tempfile.TemporaryDirectory() as td:
            M.CONTENT_DIR = td

            def must_fail(name, status):
                try:
                    M.list_missions("en")
                    check(name, False, "예외가 없어요")
                except FakeApiError as e:
                    check(name, e.status == status and bool(HANGUL.search(e.msg)), "%s %s" % (e.status, e.msg))
            must_fail("missions.json 없음 -> ApiError 503 + 한글", 503)
            path = os.path.join(td, "missions.json")
            with open(path, "w", encoding="utf-8") as f:
                f.write("{ not json")
            must_fail("missions.json 깨짐 -> ApiError 503 + 한글", 503)
            with open(path, "w", encoding="utf-8") as f:
                json.dump({"version": 1, "missions": "nope"}, f)
            must_fail("missions 가 목록이 아님 -> ApiError 503", 503)
            broken = json.loads(json.dumps(mission))
            broken["id"] = "broken_one"
            broken["goals"][0]["match"]["any"] = ["(.+)+x"]
            stage3 = json.loads(json.dumps(mission))
            stage3["id"] = "late_one"
            stage3["min_stage"] = 3
            stage3["order"] = 5
            ok1 = json.loads(json.dumps(mission))
            with open(path, "w", encoding="utf-8") as f:
                json.dump({"version": 1, "missions": [broken, "junk", {"id": "x"}, stage3, ok1]}, f)
            res = M.list_missions("en")
            ids = [m["id"] for m in res["missions"]]
            check("망가진 미션(위험 정규식·쓰레기)은 빼고 나머지는 서비스, order 순서", ids == ["late_one", mission["id"]] if stage3["order"] < ok1["order"] else ids == [mission["id"], "late_one"], ids)
            check("stage=2 에서는 min_stage 3 미션이 빠짐", [m["id"] for m in M.list_missions("en", "2")["missions"]] == [mission["id"]])
            check("stage=3 에서는 들어옴", "late_one" in [m["id"] for m in M.list_missions("en", "3")["missions"]])
            check("망가진 미션은 check 에서 404", _status(lambda: M.check_text("en", "broken_one", "hello")) == 404)
            # changed file is re-read
            with open(path, "w", encoding="utf-8") as f:
                json.dump({"version": 1, "missions": [ok1]}, f)
            time.sleep(0.02)
            check("파일이 바뀌면 다시 읽음", [m["id"] for m in M.list_missions("en")["missions"]] == [mission["id"]])
        M.CONTENT_DIR = saved_dir

        # ---- /missions/judge with a fake AI
        gid = mission["goals"][1]["id"]
        gid2 = mission["goals"][2]["id"]
        said = "I would like one latte please"
        calls = []
        script = {"out": None}

        def fake_ai(messages, schema, temperature=0.7, num_predict=1800, think=False, cache_key_kind=None):
            calls.append(messages)
            o = script["out"]
            if isinstance(o, Exception):
                raise o
            return o

        M.init(ApiError=FakeApiError, log=log, ollama_json=fake_ai)
        hist = [{"role": "ai", "text": mission["opening"]}, {"role": "me", "text": said}]

        def judge(out, pending=None, history=None, mid=None, lang="en"):
            script["out"] = out
            calls.clear()
            return M.judge_goals(lang, mid or mission["id"], pending or [gid], hist if history is None else history)

        r = judge({"goals": [{"id": gid, "done": True, "evidence": "I would like one latte"}]})
        check("judge: 증거가 내 발화 안에 있으면 done:true + evidence", r == {"ai": True, "goals": [{"id": gid, "done": True, "evidence": "I would like one latte"}]}, r)
        r = judge({"goals": [{"id": gid, "done": True, "evidence": "Can I get a large coffee"}]})
        check("judge: AI가 지어낸 증거(내 발화에 없음) -> done:false 로 정정", r["goals"] == [{"id": gid, "done": False, "evidence": ""}], r)
        r = judge({"goals": [{"id": gid, "done": True, "evidence": mission["opening"][:20]}]})
        check("judge: 증거가 상대(ai) 발화에만 있으면 -> done:false", r["goals"][0]["done"] is False, r)
        r = judge({"goals": [{"id": gid, "done": True, "evidence": ""}]})
        check("judge: 증거가 비어 있으면 -> done:false", r["goals"][0]["done"] is False, r)
        r = judge({"goals": [{"id": gid, "done": True, "evidence": "x"}]})
        check("judge: 한 글자 증거 -> done:false", r["goals"][0]["done"] is False, r)
        r = judge({"goals": [{"id": gid, "done": False, "evidence": "I would like one latte"}]})
        check("judge: AI가 done:false 라면 증거가 있어도 false", r["goals"] == [{"id": gid, "done": False, "evidence": ""}], r)
        r = judge({"goals": [{"id": gid, "done": "yes", "evidence": "I would like"}]})
        check("judge: done 이 불리언이 아니면 false", r["goals"][0]["done"] is False, r)
        r = judge({"goals": [{"id": gid, "done": True, "evidence": "\"I would like one latte\""}]})
        check("judge: 증거를 따옴표로 감싸 와도 내 발화 안의 글자만 인정", r["goals"][0]["done"] is True and r["goals"][0]["evidence"] == "I would like one latte", r)
        r = judge({"goals": []})
        check("judge: AI가 목표를 빠뜨리면 그 목표는 false", r["goals"] == [{"id": gid, "done": False, "evidence": ""}], r)
        r = judge({"goals": [{"id": "ghost", "done": True, "evidence": "I would like"}, {"id": gid, "done": True, "evidence": "latte please"}]},
                  pending=[gid, gid, "ghost2", gid2])
        check("judge: pending 의 모르는 id·중복은 무시, 순서 유지, 모르는 id 응답은 버림",
              [x["id"] for x in r["goals"]] == [gid, gid2] and r["goals"][0]["done"] is True and r["goals"][1]["done"] is False, r)
        r = judge({"goals": [{"id": gid, "done": True, "evidence": "latte please"}]}, history=[{"role": "ai", "text": "x"}])
        check("judge: 내 발화가 없으면 AI 를 부르지 않음 (호출 0회)", r["ai"] is False and calls == [] and r["goals"][0]["done"] is False, "호출 %d회" % len(calls))
        long_hist = [{"role": "me", "text": "line number %d" % i} for i in range(40)] + [{"role": "me", "text": said}]
        judge({"goals": []}, history=long_hist)
        prompt = calls[0][-1]["content"]
        check("judge: history 는 마지막 24개만 AI 에 보냄", "line number 39" in prompt and "line number 17" in prompt and "line number 16" not in prompt, "")
        junk_hist = [None, 5, "x", {"role": "bot", "text": "no"}, {"role": "me"}, {"role": "me", "text": 5}, {"role": "me", "text": "   "}, {"role": "me", "text": said}]
        r = judge({"goals": [{"id": gid, "done": True, "evidence": "latte"}]}, history=junk_hist)
        check("judge: 이상한 history 항목은 무시하고 진행", r["goals"][0]["done"] is True, r)
        judge({"goals": []}, history=[{"role": "me", "text": "x" * 5000}])
        check("judge: 발화 하나는 500자까지만 AI 에 보냄", "x" * 501 not in calls[0][-1]["content"] and "x" * 500 in calls[0][-1]["content"])
        for bad_out, label in (([1, 2], "목록"), ("text", "문자열"), (None, "None"), ({"goals": "x"}, "goals 가 문자열"), ({"nothing": 1}, "goals 없음")):
            script["out"] = bad_out
            check("judge: AI 가 %s 를 돌려주면 502 + 한글" % label, _status(lambda: M.judge_goals("en", mission["id"], [gid], hist)) == 502)
        for err, expect_status, label in ((FakeApiError("AI 모델 서버에 연결할 수 없어요.", 503), 503, "ApiError 503"), (FakeApiError("AI 응답이 너무 오래 걸려요.", 504), 504, "ApiError 504"),
                                           (FakeApiError("AI 모델 호출에 실패했어요.", 502), 502, "ApiError 502"), (RuntimeError("boom"), 502, "그 밖의 예외")):
            script["out"] = err
            st, msg = _status(lambda: M.judge_goals("en", mission["id"], [gid], hist), with_msg=True)
            check("judge: AI 가 %s 를 던지면 %d + 한글 error" % (label, expect_status), st == expect_status and bool(HANGUL.search(msg or "")), "%s %s" % (st, msg))
        check("judge: pending 비면 400", _status(lambda: M.judge_goals("en", mission["id"], [], hist)) == 400)
        check("judge: pending 이 None 이면 400", _status(lambda: M.judge_goals("en", mission["id"], None, hist)) == 400)
        check("judge: 알 수 없는 미션이면 404", _status(lambda: M.judge_goals("en", "ghost_mission", [gid], hist)) == 404)
        check("judge: lang ja/xx 이면 400", _status(lambda: M.judge_goals("ja", mission["id"], [gid], hist)) == 400 and _status(lambda: M.judge_goals("xx", mission["id"], [gid], hist)) == 400)
        M.init(ApiError=FakeApiError, log=log, ollama_json=None)
        M.H.pop("ollama_json", None)
        check("judge: AI 함수가 연결되지 않았으면 503", _status(lambda: M.judge_goals("en", mission["id"], [gid], hist)) == 503)
        M.init(ollama_json=fake_ai)

        # ---- route level (HTTP status mapping) with the fake AI
        client = TestClient(_fake_app(), raise_server_exceptions=False)
        script["out"] = FakeApiError("AI 모델 서버(Ollama)에 연결할 수 없어요.", 503)
        r = client.post("/missions/judge", json={"lang": "en", "mission_id": mission["id"], "pending": [gid], "history": hist})
        check("route: AI ApiError 503 -> HTTP 503 + {error: 한글}", r.status_code == 503 and _is_korean_error(r), "%s %s" % (r.status_code, r.text[:100]))
        script["out"] = RuntimeError("boom")
        r = client.post("/missions/judge", json={"lang": "en", "mission_id": mission["id"], "pending": [gid], "history": hist})
        check("route: AI 가 예상 못 한 예외 -> HTTP 502 (500 아님) + 한글", r.status_code == 502 and _is_korean_error(r), "%s %s" % (r.status_code, r.text[:100]))
        script["out"] = {"goals": [{"id": gid, "done": True, "evidence": "one latte"}]}
        r = client.post("/missions/judge", json={"lang": "en", "mission_id": mission["id"], "pending": [gid], "history": hist})
        check("route: 정상 -> 200, 모양 {ai, goals:[{id, done, evidence}]}", r.status_code == 200 and r.json() == {"ai": True, "goals": [{"id": gid, "done": True, "evidence": "one latte"}]}, r.text[:150])
        r = client.post("/missions/judge", json={"lang": "en", "mission_id": mission["id"], "pending": [], "history": hist})
        check("route: pending 비면 400 + 한글", r.status_code == 400 and _is_korean_error(r))
        r = client.post("/missions/judge", content="{{", headers={"Content-Type": "application/json"})
        check("route: 깨진 JSON -> 422 + 한글", r.status_code == 422 and _is_korean_error(r))
        r = client.post("/missions/check", json={"lang": "en", "mission_id": mission["id"], "text": mission["goals"][0]["pos"][0], "done": []})
        check("route: /missions/check 도 같은 라우터에서 동작", r.status_code == 200 and mission["goals"][0]["id"] in r.json()["new"])
    finally:
        M.CONTENT_DIR = saved_dir
        M.H.clear()
        M.H.update(saved_h)


def _status(fn, with_msg=False):
    try:
        fn()
        return (None, None) if with_msg else None
    except FakeApiError as e:
        return (e.status, e.msg) if with_msg else e.status
    except Exception as e:
        return (type(e).__name__, str(e)) if with_msg else type(e).__name__


def summary():
    n = {k: sum(1 for _n, s in results if s == k) for k in ("PASS", "FAIL", "UNVERIFIED", "SKIP")}
    print("\n== test_missions result: %d passed, %d failed, %d 미검증, %d skipped ==" % (n["PASS"], n["FAIL"], n["UNVERIFIED"], n["SKIP"]))
    for name, s in results:
        if s in ("FAIL", "UNVERIFIED"):
            print("  %s: %s" % (s, name))
    return 0 if n["FAIL"] == 0 and n["UNVERIFIED"] == 0 else 1


def main():
    data = run_lint(CONTENT, FULL)
    if LINT:
        if not NO_EXTRA:
            meta_lint_checks(data)
        sys.exit(summary())
    if not NO_EXTRA:
        meta_lint_checks(data)
    if not isinstance(data, dict) or not isinstance(data.get("missions"), list):
        unverified("라이브 검사", "콘텐츠를 읽지 못해서 기대값을 만들 수 없어요")
    else:
        try:
            live_tests(data)
        except Exception as e:   # an unexpected answer from the server must be a FAIL, not a stack trace
            import traceback
            check("라이브 검사가 끝까지 실행됨", False, "%s: %s (%s)" % (type(e).__name__, str(e)[:120], traceback.format_exc().strip().splitlines()[-3].strip()))
    if NO_EXTRA:
        skip("프로세스 안 검사 (가짜 AI, 이상한 콘텐츠 파일, 정규화, 정규식 방어)", "--no-extra")
        print("SKIP 1 (--no-extra)")
    else:
        extra_tests(data)
    sys.exit(summary())


if __name__ == "__main__":
    main()
