# -*- coding: utf-8 -*-
"""Generates the lock files for the install package from the LIVE dev environment.

Run it with the dev venv python (read-only use: nothing is installed into the venv):
    backend\\.venv\\Scripts\\python.exe packaging\\make_locks.py --backend backend --out packaging\\locks

Writes into --out:
    requirements.lock.txt   pip freeze of the venv (local-path entries dropped, URL entries kept)
    bootstrap.lock.txt      pip / setuptools / wheel versions of the venv (pinned by the installer)
    models.lock.json        every HF repo in backend\\models\\hf (commit, files, size, sha256) + Ollama model digest
    wheels\\                 locally built wheels for packages that are sdist-only on PyPI
"""
import argparse
import concurrent.futures
import hashlib
import json
import os
import re
import subprocess
import sys
import time
import urllib.request
import urllib.error


def norm(name):
    return re.sub(r"[-_.]+", "-", name).lower()


def run(args, **kw):
    return subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                          encoding="utf-8", errors="replace", **kw)


# ---------------------------------------------------------------------------------------------
def freeze():
    r = run([sys.executable, "-m", "pip", "freeze"])
    if r.returncode != 0:
        raise SystemExit("pip freeze failed:\n" + r.stderr)
    keep, dropped = [], []
    for line in r.stdout.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        low = line.lower()
        if line.startswith("-e ") or re.search(r"@\s*(file:|[a-z]:[\\/]|/|\.)", low):
            dropped.append(line)
            continue
        keep.append(line)
    return keep, dropped


def bootstrap_pins():
    r = run([sys.executable, "-m", "pip", "list", "--format=freeze"])
    pins = []
    for line in r.stdout.splitlines():
        m = re.match(r"^(pip|setuptools|wheel)==(\S+)$", line.strip(), re.I)
        if m:
            pins.append("%s==%s" % (m.group(1).lower(), m.group(2)))
    pins.sort(key=lambda s: (s.split("==")[0] != "pip", s))  # pip first
    return pins


# ---------------------------------------------------------------------------------------------
def pypi_has_compatible_wheel(name, ver, tags):
    """True if PyPI has a wheel for this interpreter/platform, False if sdist-only, None if unknown."""
    from packaging.utils import parse_wheel_filename
    url = "https://pypi.org/pypi/%s/%s/json" % (name, ver)
    for attempt in range(3):
        try:
            with urllib.request.urlopen(url, timeout=30) as resp:
                data = json.load(resp)
            break
        except urllib.error.HTTPError as e:
            if e.code == 404:
                return None
            time.sleep(1)
        except Exception:
            time.sleep(1)
    else:
        return None
    for f in data.get("urls", []):
        if f.get("packagetype") != "bdist_wheel":
            continue
        try:
            _, _, _, wtags = parse_wheel_filename(f["filename"])
        except Exception:
            continue
        if any(t in tags for t in wtags):
            return True
    return False


def build_sdist_wheels(pins, out_dir):
    """Find sdist-only pins and build wheels for them, so the target PC never has to compile."""
    from packaging.tags import sys_tags
    tags = set(sys_tags())
    cands = []
    for line in pins:
        m = re.match(r"^([A-Za-z0-9_.\-]+)==([^;\s]+)$", line)
        if not m:
            continue
        name, ver = m.group(1), m.group(2)
        if "+" in ver:  # local version (torch +cpu): comes from the PyTorch index
            continue
        cands.append((name, ver))
    results = {}
    with concurrent.futures.ThreadPoolExecutor(max_workers=12) as ex:
        futs = {ex.submit(pypi_has_compatible_wheel, n, v, tags): (n, v) for n, v in cands}
        for f in concurrent.futures.as_completed(futs):
            results[futs[f]] = f.result()
    sdist_only = sorted(k for k, v in results.items() if v is False)
    unknown = sorted(k for k, v in results.items() if v is None)
    for n, v in unknown:
        print("  [warn] could not query PyPI for %s==%s (assuming a wheel exists)" % (n, v))
    os.makedirs(out_dir, exist_ok=True)
    built = []
    for n, v in sdist_only:
        existing = [f for f in os.listdir(out_dir)
                    if f.lower().endswith(".whl") and norm(f.split("-")[0]) == norm(n) and f.split("-")[1] == v]
        if existing:
            built.append(existing[0])
            continue
        print("  sdist-only on PyPI: %s==%s -> building wheel" % (n, v))
        r = run([sys.executable, "-m", "pip", "wheel", "--no-deps", "--disable-pip-version-check",
                 "-w", out_dir, "%s==%s" % (n, v)])
        if r.returncode != 0:
            raise SystemExit("building wheel for %s==%s failed:\n%s" % (n, v, r.stdout[-2000:] + r.stderr[-2000:]))
        new = [f for f in os.listdir(out_dir)
               if f.lower().endswith(".whl") and norm(f.split("-")[0]) == norm(n) and f.split("-")[1] == v]
        if not new:
            raise SystemExit("no wheel produced for %s==%s" % (n, v))
        if not new[0].endswith("-none-any.whl"):
            print("  [warn] %s is a platform wheel: %s" % (n, new[0]))
        built.append(new[0])
    # drop stale wheels that are no longer needed
    for f in os.listdir(out_dir):
        if f.lower().endswith(".whl") and f not in built:
            os.remove(os.path.join(out_dir, f))
    return built


# ---------------------------------------------------------------------------------------------
def sha256_file(path, cache, cache_key):
    st = os.stat(path)
    sig = [st.st_size, st.st_mtime_ns]
    hit = cache.get(cache_key)
    if hit and hit["sig"] == sig:
        return hit["sha256"]
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while True:
            b = f.read(8 * 1024 * 1024)
            if not b:
                break
            h.update(b)
    cache[cache_key] = {"sig": sig, "sha256": h.hexdigest()}
    return h.hexdigest()


def scan_hf(hf_dir, hash_cache_path):
    cache = {}
    if os.path.isfile(hash_cache_path):
        try:
            cache = json.load(open(hash_cache_path, encoding="utf-8"))
        except Exception:
            cache = {}
    repos = []
    roots = [("", hf_dir)]
    for name in sorted(os.listdir(hf_dir)):
        p = os.path.join(hf_dir, name)
        if os.path.isdir(p) and not name.startswith("models--") and name not in ("xet", ".locks"):
            if any(x.startswith("models--") for x in os.listdir(p)):
                roots.append((name, p))
    for sub, root in roots:
        for d in sorted(os.listdir(root)):
            if not d.startswith("models--"):
                if d.startswith(("datasets--", "spaces--")):
                    print("  [warn] ignoring non-model HF cache entry", d)
                continue
            repo_id = d[len("models--"):].replace("--", "/")
            rdir = os.path.join(root, d)
            ref = os.path.join(rdir, "refs", "main")
            snaps = os.path.join(rdir, "snapshots")
            if os.path.isfile(ref):
                rev = open(ref, encoding="utf-8").read().strip()
            else:
                s = os.listdir(snaps) if os.path.isdir(snaps) else []
                if len(s) != 1:
                    raise SystemExit("cannot determine revision of %s" % repo_id)
                rev = s[0]
            sdir = os.path.join(snaps, rev)
            if not os.path.isdir(sdir):
                raise SystemExit("snapshot %s of %s missing" % (rev, repo_id))
            files = []
            for dp, _, fns in os.walk(sdir):
                for fn in sorted(fns):
                    full = os.path.join(dp, fn)
                    rel = os.path.relpath(full, sdir).replace("\\", "/")
                    key = "%s|%s|%s" % (sub, repo_id, rel)
                    files.append({"path": rel, "size": os.path.getsize(full),
                                  "sha256": sha256_file(full, cache, key)})
            files.sort(key=lambda f: f["path"])
            repos.append({"repo_id": repo_id, "cache_subdir": sub, "revision": rev, "files": files})
            print("  %s @ %s (%d files, %.1f MB)" % (repo_id, rev[:10], len(files),
                                                      sum(f["size"] for f in files) / 1e6))
    json.dump(cache, open(hash_cache_path, "w", encoding="utf-8"))
    return repos


def ollama_info(cfg, previous):
    tag = cfg.get("llm_model", "qwen3:8b")
    url = cfg.get("ollama_url", "http://127.0.0.1:11434").rstrip("/")
    try:
        with urllib.request.urlopen(url + "/api/tags", timeout=5) as r:
            data = json.load(r)
        for m in data.get("models", []):
            if m.get("name") == tag or m.get("model") == tag:
                return {"model": tag, "digest": m["digest"], "size": m["size"]}
        print("  [warn] Ollama is running but model %s is not pulled" % tag)
    except Exception as e:
        print("  [warn] Ollama not reachable (%s)" % e)
    if previous and previous.get("model") == tag:
        print("  [warn] reusing previously recorded Ollama digest")
        return previous
    raise SystemExit("cannot determine the Ollama digest for %s (start Ollama and pull the model)" % tag)


def languagetool_info(backend, previous):
    """LanguageTool zip (official URL + sha256) from backend\\tools\\languagetool\\lt.json, written when it was installed.
    The installer downloads it (about 250 MB) instead of shipping it in the package zip."""
    path = os.path.join(backend, "tools", "languagetool", "lt.json")
    if os.path.isfile(path):
        d = json.load(open(path, encoding="utf-8"))
        jar = os.path.join(backend, "tools", "languagetool", d.get("dir", ""), "languagetool-server.jar")
        if all(d.get(k) for k in ("version", "url", "sha256", "size", "dir")) and os.path.isfile(jar):
            return {k: d[k] for k in ("version", "url", "sha256", "size", "dir")}
        print("  [warn] %s is incomplete or the jar is missing" % path)
    else:
        print("  [warn] LanguageTool is not installed in backend\\tools\\languagetool")
    if previous:
        print("  [warn] reusing previously recorded LanguageTool entry")
        return previous
    print("  [warn] no LanguageTool entry: the installer will skip grammar checking (AI corrections only)")
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--backend", required=True)
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    out = os.path.abspath(a.out)
    os.makedirs(out, exist_ok=True)
    backend = os.path.abspath(a.backend)
    pyver = ".".join(map(str, sys.version_info[:3]))
    print("python %s (%s)" % (pyver, sys.executable))
    if pyver != "3.10.11":
        print("  [warn] expected the 3.10.11 venv; the embedded Python in the package is 3.10.11")

    print("== pip freeze")
    pins, dropped = freeze()
    for d in dropped:
        print("  dropped local entry:", d)
    boot = bootstrap_pins()
    with open(os.path.join(out, "requirements.lock.txt"), "w", encoding="utf-8", newline="\n") as f:
        f.write("# generated by packaging/make_locks.py from the dev venv (python %s)\n" % pyver)
        f.write("\n".join(pins) + "\n")
    with open(os.path.join(out, "bootstrap.lock.txt"), "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(boot) + "\n")
    print("  %d packages, bootstrap: %s" % (len(pins), ", ".join(boot)))

    print("== sdist-only packages")
    built = build_sdist_wheels(pins, os.path.join(out, "wheels"))
    print("  prebuilt wheels:", built or "none")

    print("== models")
    cfg = json.load(open(os.path.join(backend, "config.json"), encoding="utf-8"))
    prev_path = os.path.join(out, "models.lock.json")
    previous = prev_lt = None
    if os.path.isfile(prev_path):
        try:
            prev_lock = json.load(open(prev_path, encoding="utf-8"))
            previous, prev_lt = prev_lock.get("ollama"), prev_lock.get("languagetool")
        except Exception:
            previous = prev_lt = None
    repos = scan_hf(os.path.join(backend, "models", "hf"), os.path.join(out, ".hashcache.json"))
    ollama = ollama_info(cfg, previous)
    lt = languagetool_info(backend, prev_lt)
    lock = {"generated": time.strftime("%Y-%m-%d %H:%M:%S"), "python": pyver, "hf": repos, "ollama": ollama}
    if lt:
        lock["languagetool"] = lt
    with open(prev_path, "w", encoding="utf-8", newline="\n") as f:
        json.dump(lock, f, ensure_ascii=False, indent=1)
    print("  ollama %s digest %s" % (ollama["model"], ollama["digest"][:12]))
    if lt:
        print("  languagetool %s sha256 %s (%.0f MB, downloaded by the installer)" % (lt["version"], lt["sha256"][:12], lt["size"] / 1e6))
    print("OK")


if __name__ == "__main__":
    main()
