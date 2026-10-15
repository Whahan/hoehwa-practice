# -*- coding: utf-8 -*-
"""Downloads / verifies the Hugging Face models listed in models.lock.json.

Run by install.ps1 with the packaged runtime python:
    python -X utf8 install_models.py <models.lock.json> <backend\\models\\hf>

Every repo is fetched at the EXACT commit recorded on the source PC, only the recorded files,
and every file is verified by size + sha256. refs\\main is written afterwards so that the
server (which runs with HF_HUB_OFFLINE=1 and asks for revision "main") finds the snapshot.
"""
import hashlib
import json
import os
import sys
import threading
import time

lock_path, hf_dir = sys.argv[1], sys.argv[2]
os.makedirs(hf_dir, exist_ok=True)
os.environ["HF_HOME"] = hf_dir
os.environ["HF_HUB_CACHE"] = hf_dir
os.environ["HF_HUB_DISABLE_SYMLINKS_WARNING"] = "1"
os.environ["HF_HUB_DISABLE_TELEMETRY"] = "1"
os.environ["HF_HUB_DISABLE_PROGRESS_BARS"] = "1"
os.environ.pop("HF_HUB_OFFLINE", None)

lock = json.load(open(lock_path, encoding="utf-8"))


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while True:
            b = f.read(8 * 1024 * 1024)
            if not b:
                break
            h.update(b)
    return h.hexdigest()


def repo_paths(entry):
    base = os.path.join(hf_dir, entry["cache_subdir"]) if entry["cache_subdir"] else hf_dir
    rdir = os.path.join(base, "models--" + entry["repo_id"].replace("/", "--"))
    return base, rdir, os.path.join(rdir, "snapshots", entry["revision"])


def bad_files(entry):
    _, _, sdir = repo_paths(entry)
    bad = []
    for f in entry["files"]:
        p = os.path.join(sdir, *f["path"].split("/"))
        if not os.path.isfile(p) or os.path.getsize(p) != f["size"] or sha256(p) != f["sha256"]:
            bad.append(f["path"])
    return bad


def dir_bytes(path):
    total = 0
    for dp, _, fns in os.walk(path):
        for fn in fns:
            try:
                total += os.path.getsize(os.path.join(dp, fn))
            except OSError:
                pass
    return total


def write_ref(entry):
    _, rdir, _ = repo_paths(entry)
    os.makedirs(os.path.join(rdir, "refs"), exist_ok=True)
    with open(os.path.join(rdir, "refs", "main"), "w", encoding="utf-8", newline="") as f:
        f.write(entry["revision"])


def main():
    failures = 0
    for entry in lock["hf"]:
        repo = entry["repo_id"]
        total_mb = sum(f["size"] for f in entry["files"]) / 1e6
        bad = bad_files(entry)
        if not bad:
            write_ref(entry)
            print("  [OK]   %s (%.0f MB) - already present and verified" % (repo, total_mb), flush=True)
            continue
        print("  [GET]  %s @ %s (%.0f MB, %d files)" % (repo, entry["revision"][:10], total_mb, len(bad)), flush=True)
        from huggingface_hub import snapshot_download
        base, _, _ = repo_paths(entry)
        os.makedirs(base, exist_ok=True)
        stop = threading.Event()
        start_bytes = dir_bytes(base)

        def beat():
            t0 = time.time()
            while not stop.wait(8):
                got = (dir_bytes(base) - start_bytes) / 1e6
                print("         ... %.0f MB / %.0f MB (%ds)" % (got, total_mb, time.time() - t0), flush=True)

        th = threading.Thread(target=beat, daemon=True)
        th.start()
        err = None
        for attempt in range(1, 4):
            try:
                snapshot_download(repo_id=repo, revision=entry["revision"], cache_dir=base,
                                  allow_patterns=bad)
                err = None
                break
            except Exception as e:  # network hiccup: resume (partial files are kept)
                err = e
                print("         attempt %d failed: %s" % (attempt, str(e)[:200]), flush=True)
                time.sleep(3)
        stop.set()
        if err is not None:
            print("  [FAIL] %s: %s" % (repo, err), flush=True)
            failures += 1
            continue
        write_ref(entry)
        bad2 = bad_files(entry)
        if bad2:
            print("  [FAIL] %s: size/sha256 mismatch: %s" % (repo, ", ".join(bad2)), flush=True)
            failures += 1
        else:
            print("  [OK]   %s verified" % repo, flush=True)
    print("MODELS_RESULT %s" % ("FAIL" if failures else "OK"), flush=True)
    return 2 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
