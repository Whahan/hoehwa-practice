# -*- coding: utf-8 -*-
"""Makes this PC's prefs.json portable: drops mic_device and any value that looks like an absolute path.

    python sanitize_prefs.py <prefs.json in> <prefs.json out>
"""
import json
import re
import sys

DROP_KEYS = {"mic_device"}
PATH_RE = re.compile(r"^(?:[A-Za-z]:[\\/]|\\\\|/)")


def clean(v, key=""):
    if isinstance(v, dict):
        out = {}
        for k, x in v.items():
            if k in DROP_KEYS:
                print("  dropped key", k)
                continue
            c = clean(x, k)
            if c is not _DROP:
                out[k] = c
        return out
    if isinstance(v, list):
        return [c for c in (clean(x, key) for x in v) if c is not _DROP]
    if isinstance(v, str) and PATH_RE.match(v):
        print("  dropped absolute path in", key)
        return _DROP
    return v


_DROP = object()
data = json.load(open(sys.argv[1], encoding="utf-8"))
res = clean(data)
with open(sys.argv[2], "w", encoding="utf-8", newline="\n") as f:
    json.dump(res, f, ensure_ascii=False, indent="\t")
    f.write("\n")
print("prefs.json keys:", ", ".join(res.keys()))
