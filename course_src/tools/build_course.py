# -*- coding: utf-8 -*-
"""Manuscript -> app data. Offline, standard library only.

  python -X utf8 course_src\\tools\\build_course.py --in course_src\\en --out godot\\data\\course [--weeks 1-16]
         [--check] [--lexicon-from files|skeleton] [--tatoeba-db <path>] [--no-strict]

The linter (check_course.py, strict) always runs first; when it finds anything nothing is written and the exit code is 1.
`--check` only runs the linter (nothing is written). Output files (design section 10.1), compact one-line UTF-8 JSON:
course_manifest.json (path, bytes, sha256, records per file; no time stamp, so two builds are byte-identical),
en_weeks.json, en_lexicon.json, en_patterns.json, en_sentences.json, en_dialogues.json, en_speak_prompts.json.
"""
import argparse
import hashlib
import sys
from pathlib import Path

_HERE = str(Path(__file__).resolve().parent)
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)
import check_course as chk  # noqa: E402
import course_common as cc  # noqa: E402

MINUTES = {0: (18, 5, 12, 10), 1: (15, 10, 8, 12), 2: (15, 10, 8, 12), 3: (12, 12, 8, 13), 4: (12, 12, 8, 13),
           5: (10, 10, 10, 15), 6: (10, 10, 10, 15)}
FILES = ["en_weeks.json", "en_lexicon.json", "en_patterns.json", "en_sentences.json", "en_dialogues.json", "en_speak_prompts.json"]


def ladder_of(w):
    return {"repeat": True, "substitute": w >= 2, "script": w >= 8,
            "mission": "none" if w < 13 else "script" if w < 25 else "ai",
            "free": "none" if w < 17 else "guided" if w < 33 else "free" if w < 57 else "open"}


def minutes_of(w):
    n, r, l, s = MINUTES[cc.stage_of_week(w)]
    return {"new": n, "review": r, "listen": l, "speak": s}


def build_data(course, weeks, lex):
    """-> {file name: (object, records)} for the weeks (all must exist and pass the linter)."""
    skel = {x.get("w"): x for x in course.skeleton_weeks()}
    pat_o = cc.pattern_o_map(course)
    weeks_out, lex_out, pats_out, sent_out, dlg_out, prm_out = [], [], [], [], [], []
    for w in weeks:
        wk = course.weeks[w]
        sk = skel.get(w, {})
        words = wk.get("words", [])
        active = sorted((x for x in words if x["role"] == "active"), key=lambda x: (x["d"], x["id"]))
        passive = sorted((x for x in words if x["role"] == "passive"), key=lambda x: (x["d"], x["id"]))
        pats = wk.get("patterns", [])
        days = []
        for d in range(1, cc.DAY_MAX + 1):
            if d <= cc.WORD_DAY_MAX:
                days.append({"d": d, "kind": "new", "words": [x["id"] for x in active if x["d"] == d],
                             "patterns": [p["id"] for i, p in enumerate(pats) if cc.week_pattern_day(i, p) == d]})
            else:
                days.append({"d": d, "kind": {5: "speak", 6: "check", 7: "free"}[d], "words": [], "patterns": []})
        ladder = dict(ladder_of(w))
        if isinstance(sk.get("ladder"), dict):
            ladder.update(sk["ladder"])
        check = {"items": 12, "pass": 80, "month": w % 4 == 0}
        if isinstance(sk.get("check"), dict):
            check.update(sk["check"])
        minutes = minutes_of(w)
        if isinstance(sk.get("minutes"), dict):
            minutes.update(sk["minutes"])
        scene = wk.get("scene") if isinstance(wk.get("scene"), dict) else sk.get("scene") if isinstance(sk.get("scene"), dict) else {"id": "", "title_ko": "", "canada": []}
        weeks_out.append({
            "w": w, "n": (w - 1) // 4 + 1, "k": (w - 1) % 4 + 1, "stage": cc.stage_of_week(w), "legacy_stage": cc.legacy_stage(w),
            "title_ko": wk.get("title_ko") if cc.is_str(wk.get("title_ko")) else sk.get("title_ko", ""),
            "can_do": wk.get("can_do") if isinstance(wk.get("can_do"), list) else sk.get("can_do", []),
            "scene": scene,
            "words": {"new": [x["id"] for x in active], "passive": [x["id"] for x in passive]},
            "patterns": [p["id"] for p in pats],
            "dialogue": wk["dialogues"][0]["id"] if wk.get("dialogues") else "",
            "ladder": ladder, "days": days, "check": check, "minutes": minutes,
            "notes": [dict((k, v) for k, v in n.items() if not k.startswith("_") and k != "note") for n in wk.get("notes", [])]})
        for x in sorted(words, key=lambda x: (w * 10 + x["d"], x["id"])):
            o = w * 10 + x["d"]
            rec = {"id": x["id"], "en": x["en"], "pos": x["pos"], "ko": x["ko"]}
            if x.get("ko2"):
                rec["ko2"] = x["ko2"]
            rec.update({"ipa": x["ipa"], "say": x.get("say", ""), "tags": x.get("tags", []), "role": x["role"], "o": o,
                        "forms": [{"f": f["f"], "pat": f["pat"], "o": max(o, pat_o.get(f["pat"], 0))} for f in x.get("forms", [])],
                        "alt": x.get("alt", []), "syn": x.get("syn", []), "ca": bool(x.get("ca", False)), "src": x.get("src", "own")})
            lex_out.append(rec)
        sent_by_pat = {}
        for s in wk.get("sentences", []):
            if s.get("pat"):
                sent_by_pat.setdefault(s["pat"], []).append(s["id"])
        for i, p in enumerate(pats):
            pats_out.append({"id": p["id"], "tpl": p["tpl"], "slots": p.get("slots", []), "title_ko": p["title_ko"],
                             "grammar_ko": p["grammar_ko"], "o": w * 10 + cc.week_pattern_day(i, p),
                             "examples": p.get("examples") if isinstance(p.get("examples"), list) else sorted(sent_by_pat.get(p["id"], []))})
        for s in wk.get("sentences", []):
            toks = cc.item_tokens(s["en"], s.get("say", ""), lex.acronym_map(), lex.is_word)
            decl = w * 10 + s["d"] if cc.is_int(s.get("d")) else None
            o = decl if decl is not None else max([w * 10 + 1] + [lex.min_o(t) or 0 for t in toks])
            sent_out.append({"id": s["id"], "en": s["en"], "ko": s["ko"], "say": s.get("say", ""),
                             "words": sorted(lex.used_words(toks, o)), "pat": s.get("pat", ""), "o": o,
                             "scope": s.get("scope", "all"), "accept": s.get("accept", []), "src": s.get("src", "own"),
                             "tid": s.get("tid", 0) if s.get("src") == "tatoeba" else 0})
        for dlg in wk.get("dialogues", []):
            ddef = dlg["d"] if cc.is_int(dlg.get("d")) else 4
            lines = []
            for ln in dlg["lines"]:
                o = w * 10 + (ln["d"] if cc.is_int(ln.get("d")) else ddef)
                toks = cc.item_tokens(ln["en"], ln.get("say", ""), lex.acronym_map(), lex.is_word)
                rec = {"s": ln["s"], "en": ln["en"], "ko": ln["ko"], "say": ln.get("say", ""),
                       "words": sorted(lex.used_words(toks, o)), "o": o}
                for k in ("hint_ko", "accept"):
                    if k in ln:
                        rec[k] = ln[k]
                lines.append(rec)
            dlg_out.append({"id": dlg["id"], "w": w, "title_ko": dlg["title_ko"], "scene": dlg.get("scene", ""),
                            "user": dlg.get("user", "B"), "lines": lines})
        for x in wk.get("speak_prompts", []):
            n = (w - 1) // 4 + 1
            grp = next((g for g in prm_out if g["month"] == n), None)
            if grp is None:
                grp = {"month": n, "w": w, "prompts": []}
                prm_out.append(grp)
            grp["prompts"].append({"id": x["id"], "kind": x["kind"], "en": x["en"], "ko": x["ko"], "say": x.get("say", ""),
                                   "expect_any": x["expect_any"], "o": w * 10 + cc.SPEAK_PROMPT_DAY})
    sent_out.sort(key=lambda s: (s["o"], s["id"]))
    wrap = lambda key, arr: {"v": 1, "lang": "en", key: arr}  # noqa: E731
    return {"en_weeks.json": (wrap("weeks", weeks_out), len(weeks_out)),
            "en_lexicon.json": (wrap("words", lex_out), len(lex_out)),
            "en_patterns.json": (wrap("patterns", pats_out), len(pats_out)),
            "en_sentences.json": (wrap("sentences", sent_out), len(sent_out)),
            "en_dialogues.json": (wrap("dialogues", dlg_out), len(dlg_out)),
            "en_speak_prompts.json": (wrap("prompts", prm_out), len(prm_out))}


def to_bytes(obj):
    return (cc.dumps_compact(obj) + "\n").encode("utf-8")


def build_files(in_dir, weeks_arg=None, lexicon_from="files", tatoeba_db=None, strict=True):
    """-> (ok, {file name: bytes}, check_lines). Nothing is written here."""
    res = chk.run_check(in_dir, weeks_arg, strict=strict, lexicon_from=lexicon_from, tatoeba_db=tatoeba_db)
    lines = chk.format_result(res)
    if res.violations:
        return False, {}, lines
    course = cc.Course(in_dir).load()
    weeks = [w for w in cc.select_weeks(course, weeks_arg) if w in course.weeks]
    if not weeks:
        return False, {}, lines + ["BUILD_FAIL no_weeks"]
    lex = cc.build_lexicon(course, lexicon_from, list(course.weeks))
    data = build_data(course, weeks, lex)
    blobs = {name: to_bytes(obj) for name, (obj, _n) in data.items()}
    manifest = {"v": 1, "lang": "en", "weeks": [weeks[0], weeks[-1]], "count": len(weeks),
                "files": [{"path": n, "bytes": len(blobs[n]), "sha256": hashlib.sha256(blobs[n]).hexdigest(), "records": data[n][1]}
                          for n in sorted(blobs)]}
    blobs["course_manifest.json"] = to_bytes(manifest)
    return True, blobs, lines


def main(argv=None):
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except (AttributeError, OSError):
        pass
    ap = argparse.ArgumentParser(description="Build the course data from the manuscript")
    ap.add_argument("--in", dest="in_dir", required=True)
    ap.add_argument("--out", default=None)
    ap.add_argument("--weeks", default=None)
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--lexicon-from", dest="lexicon_from", choices=["files", "skeleton"], default="files")
    ap.add_argument("--tatoeba-db", dest="tatoeba_db", default=None)
    ap.add_argument("--no-strict", dest="no_strict", action="store_true")
    a = ap.parse_args(argv)
    try:
        weeks_arg = cc.parse_weeks_arg(a.weeks)
    except ValueError:
        print("BUILD_FAIL bad_weeks_argument")
        return 1
    if not a.check and not a.out:
        print("BUILD_FAIL --out is required (or use --check)")
        return 1
    ok, blobs, lines = build_files(a.in_dir, weeks_arg, a.lexicon_from, a.tatoeba_db, strict=not a.no_strict)
    for ln in lines:
        print(ln)
    if not ok:
        print("BUILD_FAIL check_failed (nothing written)")
        return 1
    if a.check:
        print("BUILD_CHECK_OK files=%d" % len(blobs))
        return 0
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    for name, b in blobs.items():
        (out / name).write_bytes(b)
    total = sum(len(b) for b in blobs.values())
    print("BUILD_OK files=%d bytes=%d out=%s" % (len(blobs), total, out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
