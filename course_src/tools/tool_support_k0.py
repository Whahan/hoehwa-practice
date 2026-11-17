# -*- coding: utf-8 -*-
"""Skeleton in the design 10.2 / K0 layout for the tests (not a test module). Standard library only."""
import copy
from pathlib import Path

import tool_support as ts


def to_k0_layout(sk):
    """Convert a skeleton in the older test layout into the K0 layout: week patterns are ids with the bodies in a
    top-level `patterns` list, the assignment table is the top-level `words` list, notes are ids in top-level
    `canada_notes`, week `words` = {new, passive} id lists, `days[].words`, `review` flag, K0 style id_ranges."""
    sk = copy.deepcopy(sk)
    pats, notes = [], []
    assign = sk.pop("assign", [])
    for wk in sk["weeks"]:
        ids = []
        for i, p in enumerate(wk.get("patterns", [])):
            pats.append(dict(p, w=wk["w"], d=min(i + 1, 4)))
            ids.append(p["id"])
        wk["patterns"] = ids
        new_ids = []
        for j, _c in enumerate(wk.get("scene", {}).get("canada", [])):
            nid = "cn_w%d_%d" % (wk["w"], j)
            notes.append({"id": nid, "w": wk["w"], "kind": "culture", "ca": "", "alt": [], "note_ko": "노트"})
            new_ids.append(nid)
        if "scene" in wk:
            wk["scene"]["canada"] = new_ids
        mine = [a for a in assign if a["w"] == wk["w"]]
        if mine:
            wk["words"] = {"new": [a["id"] for a in mine if a["role"] == "active"],
                           "passive": [a["id"] for a in mine if a["role"] == "passive"]}
            wk["days"] = [{"d": d, "kind": "new", "words": [a["id"] for a in mine if a["role"] == "active" and a["d"] == d],
                           "patterns": [p["id"] for p in pats if p["w"] == wk["w"] and p["d"] == d]} for d in range(1, 5)] + \
                         [{"d": 5, "kind": "speak"}, {"d": 6, "kind": "check"}, {"d": 7, "kind": "free"}]
            wk["counts"] = {"active": len(wk["words"]["new"]), "passive": len(wk["words"]["passive"]), "patterns": len(ids)}
        else:
            wk["counts"]["patterns"] = len(ids)
        wk["review"] = wk["w"] in (16, 32, 48, 60, 68) or wk["w"] >= 69
    sk["patterns"], sk["words"], sk["canada_notes"] = pats, assign, notes
    ir = sk["id_ranges"]
    words = {"assigned": ["w0001", "w0550"]}
    for i, n in enumerate(ir):
        words[n] = ["w%04d" % (551 + 30 * i), "w%04d" % (580 + 30 * i)]
    sk["id_ranges"] = {"words": words,
                       "sentences": {n: e["sentences"] for n, e in ir.items()},
                       "dialogues": {n: e["dialogues"] for n, e in ir.items()},
                       "authors": {n: e["weeks"] for n, e in ir.items()}}
    return sk


def write_k0_skeleton_course(root, mutate=None, policy=None):
    sk = to_k0_layout(ts.valid_skeleton())
    if mutate:
        mutate(sk)
    root = Path(root)
    root.mkdir(parents=True, exist_ok=True)
    (root / "skeleton.json").write_bytes(ts.mf.dump(sk).encode("utf-8"))
    pol = policy or {"v": 1, "blocked": {"profanity": ["fuck"]}, "blocked_prefix": ["shit"]}
    (root / "policy.json").write_bytes(ts.mf.dump(pol).encode("utf-8"))
    return root
