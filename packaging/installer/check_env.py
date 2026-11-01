# -*- coding: utf-8 -*-
"""Compares `pip freeze` of the running interpreter with requirements.lock.txt (+ bootstrap pins).

    python -X utf8 check_env.py <requirements.lock.txt> [bootstrap.lock.txt] [--gpu auto|nvidia|cpu]

--gpu cpu    : the NVIDIA runtime libraries (cuBLAS, cuDNN, nvrtc) are NOT expected: they are removed from the wanted
               list, and having them installed is reported as EXTRA.
--gpu nvidia : the lock is used as it is (missing NVIDIA libraries are reported as MISSING).
--gpu auto   : (default) read runtime\\.state\\gpu.txt next to this vendor folder ("cpu" / "nvidia"); no file = nvidia.
Test hook (only with HOEHWA_TEST_MODE=1): HOEHWA_FREEZE_FILE=<file> is read instead of running `pip freeze`.
Exit code 0 = identical (pip/setuptools/wheel are compared separately and only warned about).
"""
import argparse
import os
import re
import subprocess
import sys

NVIDIA_LIBS = ("nvidia-cublas-cu12", "nvidia-cudnn-cu12", "nvidia-cuda-nvrtc-cu12")


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


def gpu_kind(arg):
    if arg in ("cpu", "nvidia"):
        return arg
    here = os.path.dirname(os.path.abspath(__file__))
    gpu_txt = os.path.join(here, "..", "runtime", ".state", "gpu.txt")
    try:
        with open(gpu_txt, encoding="utf-8") as f:
            v = f.read().strip().lower()
        return "cpu" if v == "cpu" else "nvidia"
    except OSError:
        return "nvidia"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("lock")
    ap.add_argument("bootstrap", nargs="?")
    ap.add_argument("--gpu", choices=("auto", "nvidia", "cpu"), default="auto")
    a = ap.parse_args()

    kind = gpu_kind(a.gpu)
    want = parse(open(a.lock, encoding="utf-8").read().splitlines())
    if kind == "cpu":
        for k in NVIDIA_LIBS:
            want.pop(k, None)

    freeze_file = os.environ.get("HOEHWA_FREEZE_FILE") if os.environ.get("HOEHWA_TEST_MODE") == "1" else None
    if freeze_file:
        text = open(freeze_file, encoding="utf-8").read()
        have = parse(text.splitlines())
        have2 = None
    else:
        r = subprocess.run([sys.executable, "-m", "pip", "freeze"], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                           text=True, encoding="utf-8", errors="replace")
        have = parse(r.stdout.splitlines())
        have2 = None

    missing = sorted(set(want) - set(have))
    extra = sorted(set(have) - set(want))
    diff = sorted(k for k in want if k in have and want[k] != have[k])
    for k in missing:
        print("MISSING   %s==%s" % (k, want[k]))
    for k in extra:
        print("EXTRA     %s==%s" % (k, have[k]))
    for k in diff:
        print("DIFFERENT %s: want %s have %s" % (k, want[k], have[k]))
    if a.bootstrap:
        boot = parse(open(a.bootstrap, encoding="utf-8").read().splitlines())
        if freeze_file:   # a pip freeze never lists pip/setuptools, so the pins cannot be compared against it
            print("BOOTSTRAP check skipped (HOEHWA_FREEZE_FILE test hook)")
            boot = {}
        elif have2 is None:
            r2 = subprocess.run([sys.executable, "-m", "pip", "list", "--format=freeze"], stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, text=True, encoding="utf-8", errors="replace")
            have2 = parse(r2.stdout.splitlines())
        for k, v in boot.items():
            if have2.get(k) != v:
                print("BOOTSTRAP %s: want %s have %s" % (k, v, have2.get(k)))
                diff.append(k)
    ok = not (missing or extra or diff)
    print("ENV_RESULT %s (%d packages checked, gpu=%s)" % ("OK" if ok else "MISMATCH", len(want), kind))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
