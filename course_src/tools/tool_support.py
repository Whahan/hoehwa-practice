# -*- coding: utf-8 -*-
"""Helpers shared by the test files (not a test module). Standard library only."""
import copy
import json
import subprocess
import sys
import tempfile
from pathlib import Path

TOOLS = Path(__file__).resolve().parent
FIX = TOOLS / "fixtures"
if str(TOOLS) not in sys.path:
    sys.path.insert(0, str(TOOLS))
import make_fixtures as mf  # noqa: E402


def cli(script, *args, timeout=120):
    """Run a tool in a fresh interpreter -> (exit code, stdout lines)."""
    p = subprocess.run([sys.executable, "-I", "-X", "utf8", str(TOOLS / script)] + [str(a) for a in args],
                       capture_output=True, timeout=timeout, encoding="utf-8", errors="replace")
    return p.returncode, [ln for ln in p.stdout.splitlines()], p.stderr


def check(*args):
    code, lines, err = cli("check_course.py", *args)
    return code, lines


def codes_of(lines):
    """violation codes in a result (detail lines look like '  CODE where detail')."""
    out = []
    for ln in lines:
        parts = ln.split()
        if len(parts) >= 2 and ln.startswith("  ") and parts[0].isupper():
            out.append(parts[0])
    return out


def write_course(root, mutate=None, files=None):
    """Write good_mini (optionally mutated by `mutate(d)`, d = {relative path: object}) under root, -> Path."""
    d = copy.deepcopy(mf.good())
    if mutate:
        mutate(d)
    root = Path(root)
    for rel, obj in d.items():
        p = root / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(mf.dump(obj).encode("utf-8"))
    for rel, text in (files or {}).items():
        p = root / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(text.encode("utf-8"))
    return root


def tmpdir():
    return tempfile.TemporaryDirectory(prefix="course_k1_")


def find(d, w, kind, ident):
    return next(x for x in d["weeks/w%03d.json" % w][kind] if x["id"] == ident)


def valid_skeleton():
    """A 72-week skeleton that satisfies every --skeleton rule (weeks 1-16 carry the assignment table)."""
    import check_course  # noqa: F401
    weeks, assign = [], []
    n_word = 0
    for w in range(1, 73):
        cls = "intro" if w <= 4 else "synth" if w in (16, 32, 48, 60, 68) else "final" if w >= 69 else "normal"
        act = {"intro": 25, "normal": 25, "synth": 13, "final": 19}[cls]
        if w == 16:
            pas = 9
        elif w <= 4:
            pas = 0
        elif w <= 15:
            pas = 11
        else:
            pas = {"normal": 14, "synth": 10, "final": 16}[cls]
        pats = [{"id": "p_w%02d_%d" % (w, i + 1), "tpl": "word %d ___." % (i + 1), "title_ko": "문형 %d" % (i + 1),
                 "grammar_ko": ["첫째 줄이에요.", "둘째 줄이에요."]} for i in range(2 if cls != "normal" else 3)]
        wk = {"w": w, "n": (w - 1) // 4 + 1, "k": (w - 1) % 4 + 1, "stage": 0, "legacy_stage": 1,
              "title_ko": "주 %d" % w, "can_do": ["할 수 있다 하나", "할 수 있다 둘"],
              "scene": {"id": "s%d" % w, "title_ko": "장면", "canada": ["노트"]}, "ladder": {}, "check": {}, "minutes": {},
              "patterns": pats}
        import course_common as cc
        wk["stage"], wk["legacy_stage"] = cc.stage_of_week(w), cc.legacy_stage(w)
        if w <= 16:
            days = {1: 7, 2: 6, 3: 6, 4: act - 19} if act == 25 else {1: 4, 2: 3, 3: 3, 4: act - 10}
            seq = []
            for d, k in days.items():
                seq += [(d, "active")] * k
            seq += [(1 + i % 4, "passive") for i in range(pas)]
            for d, role in seq:
                n_word += 1
                assign.append({"id": "w%04d" % n_word, "lemma": "lemma%04d" % n_word, "pos": "n", "role": role, "w": w, "d": d})
        else:
            wk["counts"] = {"active": act, "passive": pas, "patterns": len(pats)}
        weeks.append(wk)
    rng = lambda a, b, c, d, e, f: {"weeks": [a, b], "words": ["w%04d" % c, "w%04d" % d], "sentences": ["s%04d" % e, "s%04d" % f],  # noqa: E731
                                    "dialogues": ["d%04d" % a, "d%04d" % (a + 3)]}
    sk = {"v": 1, "lang": "en",
          "id_ranges": {"A1": rng(1, 4, 1, 100, 1, 249), "A2": rng(5, 8, 101, 250, 250, 499),
                        "A3": rng(9, 12, 251, 400, 500, 749), "A4": rng(13, 16, 401, 550, 750, 999)},
          "weeks": weeks, "assign": assign}
    # the dialogue id ranges of the authors must not overlap: A1 d0001-0004, A2 d0005-0008 ...
    return sk


def write_skeleton_course(root, mutate=None):
    sk = valid_skeleton()
    if mutate:
        mutate(sk)
    root = Path(root)
    root.mkdir(parents=True, exist_ok=True)
    (root / "skeleton.json").write_bytes(mf.dump(sk).encode("utf-8"))
    (root / "policy.json").write_bytes(mf.dump({"v": 1, "blocked": ["fuck*"], "names": ["Min"]}).encode("utf-8"))
    return root
