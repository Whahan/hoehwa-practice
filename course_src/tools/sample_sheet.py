# -*- coding: utf-8 -*-
"""Stratified sample sheet for the human review (design 9.4). Offline, standard library only.

  python -X utf8 course_src\\tools\\sample_sheet.py --in course_src\\en --n 300 --seed 7 --out <sheet.csv> [--weeks 1-16]

Strata and shares (of n): words 30 %, sentences 40 %, dialogue lines 50/300, Korean grammar explanations 40/300
(largest-remainder rounding, so each stratum is within +-1 of its share; a stratum with too few items hands its
surplus to the others). Same seed -> same file. CSV header: id,type,en,ko,say,note,verdict (verdict is left empty;
the reviewer writes OK / M / C). The file is UTF-8 with a BOM so that Excel shows Korean correctly.
"""
import argparse
import csv
import random
import sys
from pathlib import Path

_HERE = str(Path(__file__).resolve().parent)
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)
import course_common as cc  # noqa: E402

HEADER = ["id", "type", "en", "ko", "say", "note", "verdict"]
SHARES = [("word", 90), ("sentence", 120), ("dialogue_line", 50), ("grammar", 40)]   # of 300


def collect(course, weeks):
    pools = {k: [] for k, _ in SHARES}
    for w in weeks:
        wk = course.weeks.get(w)
        if not wk:
            continue
        for x in wk.get("words", []) or []:
            pools["word"].append([x["id"], "word", x["en"], x["ko"], x.get("say", ""),
                                  "w=%d pos=%s role=%s ipa=%s" % (w, x.get("pos"), x.get("role"), x.get("ipa", "")), ""])
        for x in wk.get("sentences", []) or []:
            pools["sentence"].append([x["id"], "sentence", x["en"], x["ko"], x.get("say", ""),
                                      "w=%d pat=%s src=%s" % (w, x.get("pat", ""), x.get("src", "own")), ""])
        for dlg in wk.get("dialogues", []) or []:
            for i, ln in enumerate(dlg.get("lines", []) or [], 1):
                pools["dialogue_line"].append(["%s#%d" % (dlg["id"], i), "dialogue_line", ln["en"], ln["ko"], ln.get("say", ""),
                                               "w=%d speaker=%s" % (w, ln.get("s")), ""])
        for x in wk.get("patterns", []) or []:
            pools["grammar"].append([x["id"], "grammar", x["tpl"], " / ".join(x.get("grammar_ko", [])), "",
                                     "w=%d %s" % (w, x.get("title_ko", "")), ""])
    return pools


def allocate(n, sizes):
    """Largest-remainder allocation of n over the strata by SHARES, capped by pool sizes (surplus is passed on)."""
    total_share = sum(s for _, s in SHARES)
    n = min(n, sum(sizes.values()))
    quota = {k: 0 for k, _ in SHARES}
    open_keys = [k for k, _ in SHARES if sizes[k] > 0]
    left = n
    while left > 0 and open_keys:
        share = {k: dict(SHARES)[k] for k in open_keys}
        tot = sum(share.values())
        raw = {k: left * share[k] / tot for k in open_keys}
        base = {k: int(raw[k]) for k in open_keys}
        rem = left - sum(base.values())
        for k in sorted(open_keys, key=lambda k: (-(raw[k] - base[k]), [x for x, _ in SHARES].index(k)))[:rem]:
            base[k] += 1
        capped = [k for k in open_keys if quota[k] + base[k] > sizes[k]]
        if not capped:
            for k in open_keys:
                quota[k] += base[k]
            left = 0
        else:
            for k in capped:
                left -= sizes[k] - quota[k]
                quota[k] = sizes[k]
                open_keys.remove(k)
    return quota


def make_sheet(course, weeks, n, seed):
    pools = collect(course, weeks)
    quota = allocate(n, {k: len(v) for k, v in pools.items()})
    rng = random.Random(seed)
    rows = []
    for k, _ in SHARES:
        pool = sorted(pools[k], key=lambda r: r[0])
        rows += rng.sample(pool, quota[k]) if quota[k] else []
    order = {k: i for i, (k, _) in enumerate(SHARES)}
    rows.sort(key=lambda r: (order[r[1]], r[0]))
    return rows, quota


def write_csv(path, rows):
    with open(path, "w", encoding="utf-8-sig", newline="") as f:
        wr = csv.writer(f)
        wr.writerow(HEADER)
        wr.writerows(rows)


def main(argv=None):
    ap = argparse.ArgumentParser(description="Stratified review sample sheet")
    ap.add_argument("--in", dest="in_dir", required=True)
    ap.add_argument("--n", type=int, default=300)
    ap.add_argument("--seed", type=int, required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--weeks", default=None)
    a = ap.parse_args(argv)
    try:
        weeks_arg = cc.parse_weeks_arg(a.weeks)
    except ValueError:
        print("SAMPLE_FAIL bad_weeks_argument")
        return 1
    if a.n < 1:
        print("SAMPLE_FAIL n_must_be_positive")
        return 1
    course = cc.Course(a.in_dir).load()
    if any(p.code == "SCHEMA" for p in course.problems) or not course.weeks:
        print("SAMPLE_FAIL manuscript_not_loadable")
        return 1
    rows, quota = make_sheet(course, cc.select_weeks(course, weeks_arg), a.n, a.seed)
    write_csv(a.out, rows)
    print("SAMPLE_OK rows=%d %s seed=%d out=%s" % (len(rows), " ".join("%s=%d" % kv for kv in quota.items()), a.seed, a.out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
