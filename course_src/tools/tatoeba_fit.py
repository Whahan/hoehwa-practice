# -*- coding: utf-8 -*-
"""How many Tatoeba sentences (with a Korean translation) use only words taught up to week w?  Read-only, offline.

  python -X utf8 course_src\\tools\\tatoeba_fit.py --in course_src\\en [--weeks 1-16] [--lexicon-from files|skeleton]
         [--db <tatoeba.sqlite>] [--show 5] [--json <out.json>]

For every week w in the range: `cum` = Tatoeba sentences whose tokens are ALL words with o <= w*10+7 (everything taught
through week w), `new` = those that became possible in this week (not in week w-1). Sentences with digits or a Korean
translation without Hangul are skipped. The database is opened read-only (`mode=ro`); default
<repo>\\backend\\data\\tatoeba.sqlite, then the main checkout's copy next to this worktree. `--show N` prints N example
ids (id, English text, Korean text from the CC BY 2.0 FR corpus) per week.
"""
import argparse
import json
import sqlite3
import sys
from pathlib import Path

_HERE = str(Path(__file__).resolve().parent)
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)
import course_common as cc  # noqa: E402


def find_db(arg=None):
    cands = [Path(arg)] if arg else [cc.REPO_ROOT / "backend" / "data" / "tatoeba.sqlite",
                                     cc.REPO_ROOT.parent / "app" / "backend" / "data" / "tatoeba.sqlite",
                                     cc.REPO_ROOT.parent.parent / "app" / "backend" / "data" / "tatoeba.sqlite"]
    for p in cands:
        if p.is_file():
            return p
    return None


def load_sentences(path):
    """-> list of (id, en, ko, token tuple) for English sentences that have a Korean translation."""
    con = sqlite3.connect(Path(path).resolve().as_uri() + "?mode=ro", uri=True)
    try:
        rows = con.execute("SELECT id, text, ko FROM sent WHERE lang='en' AND ko IS NOT NULL AND ko != ''").fetchall()
    finally:
        con.close()
    out = []
    for sid, en, ko in rows:
        if not cc.HANGUL.search(ko or ""):
            continue
        toks = cc.tokenize(en)
        if toks and not any(any(ch.isdigit() for ch in t) for t in toks):
            out.append((int(sid), en, ko, tuple(toks)))
    return out


def fit(sents, lex, weeks):
    """-> {w: {"cum": n, "new": n, "ids": [ids that are new this week]}}"""
    need = []
    for sid, en, ko, toks in sents:
        os_ = [lex.min_o(t) for t in toks]
        need.append(None if any(o is None for o in os_) else max(os_))
    res, prev = {}, set()
    for w in weeks:
        lim = w * 10 + cc.DAY_MAX
        cur = {sents[i][0] for i, n in enumerate(need) if n is not None and n <= lim}
        res[w] = {"cum": len(cur), "new": len(cur - prev), "ids": sorted(cur - prev)}
        prev = cur
    return res


def main(argv=None):
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except (AttributeError, OSError):
        pass
    ap = argparse.ArgumentParser(description="Tatoeba candidates per week")
    ap.add_argument("--in", dest="in_dir", required=True)
    ap.add_argument("--weeks", default=None)
    ap.add_argument("--lexicon-from", dest="lexicon_from", choices=["files", "skeleton"], default="files")
    ap.add_argument("--db", default=None)
    ap.add_argument("--show", type=int, default=0)
    ap.add_argument("--json", default=None)
    a = ap.parse_args(argv)
    try:
        weeks_arg = cc.parse_weeks_arg(a.weeks)
    except ValueError:
        print("FIT_FAIL bad_weeks_argument")
        return 1
    db = find_db(a.db)
    if db is None:
        print("FIT_FAIL tatoeba_database_not_found (not verified)")
        return 1
    course = cc.Course(a.in_dir).load()
    if any(p.code == "SCHEMA" for p in course.problems):
        print("FIT_FAIL manuscript_not_loadable")
        return 1
    if weeks_arg is None:
        if a.lexicon_from == "skeleton":
            weeks = sorted({x["w"] for x in course.skeleton_assign() if cc.is_int(x.get("w"))})
        else:
            weeks = sorted(course.weeks)
    else:
        weeks = list(range(weeks_arg[0], weeks_arg[1] + 1))
    if not weeks:
        print("FIT_FAIL no_weeks")
        return 1
    lex = cc.build_lexicon(course, a.lexicon_from)
    try:
        sents = load_sentences(db)
    except sqlite3.Error:
        print("FIT_FAIL tatoeba_database_unreadable")
        return 1
    res = fit(sents, lex, weeks)
    by_id = {s[0]: s for s in sents}
    for w in weeks:
        print("FIT week=%d cum=%d new=%d" % (w, res[w]["cum"], res[w]["new"]))
        for sid in res[w]["ids"][:max(0, a.show)]:
            s = by_id[sid]
            print("  id=%d en=%s ko=%s" % (sid, s[1], s[2]))
    print("FIT_OK weeks=%d-%d database_sentences=%d" % (weeks[0], weeks[-1], len(sents)))
    if a.json:
        Path(a.json).write_text(json.dumps({str(w): {"cum": r["cum"], "new": r["new"]} for w, r in res.items()}, indent=1) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())
