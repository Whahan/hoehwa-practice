# -*- coding: utf-8 -*-
"""Compares `pip freeze` of the running interpreter with requirements.lock.txt (+ bootstrap pins).

    python -X utf8 check_env.py <requirements.lock.txt> [bootstrap.lock.txt]
Exit code 0 = identical (pip/setuptools/wheel are compared separately and only warned about).
"""
import re
import subprocess
import sys


def norm(n):
    return re.sub(r"[-_.]+", "-", n).lower()


def parse(lines):
    d = {}
    for line in lines:
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        m = re.match(r"^([A-Za-z0-9_.\-]+)\s*(?:==\s*(\S+)|@\s*(\S+))", line)
        if not m:
            continue
        ver = m.group(2) or m.group(3).split("#")[0]
        d[norm(m.group(1))] = ver
    return d


want = parse(open(sys.argv[1], encoding="utf-8").read().splitlines())
r = subprocess.run([sys.executable, "-m", "pip", "freeze"], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                   text=True, encoding="utf-8", errors="replace")
have = parse(r.stdout.splitlines())
missing = sorted(set(want) - set(have))
extra = sorted(set(have) - set(want))
diff = sorted(k for k in want if k in have and want[k] != have[k])
for k in missing:
    print("MISSING   %s==%s" % (k, want[k]))
for k in extra:
    print("EXTRA     %s==%s" % (k, have[k]))
for k in diff:
    print("DIFFERENT %s: want %s have %s" % (k, want[k], have[k]))
if len(sys.argv) > 2:
    boot = parse(open(sys.argv[2], encoding="utf-8").read().splitlines())
    r2 = subprocess.run([sys.executable, "-m", "pip", "list", "--format=freeze"], stdout=subprocess.PIPE,
                        stderr=subprocess.PIPE, text=True, encoding="utf-8", errors="replace")
    have2 = parse(r2.stdout.splitlines())
    for k, v in boot.items():
        if have2.get(k) != v:
            print("BOOTSTRAP %s: want %s have %s" % (k, v, have2.get(k)))
            diff.append(k)
print("ENV_RESULT %s (%d packages checked)" % ("OK" if not (missing or extra or diff) else "MISMATCH", len(want)))
sys.exit(0 if not (missing or extra or diff) else 1)
