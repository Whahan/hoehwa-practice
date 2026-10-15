# -*- coding: utf-8 -*-
"""Helper for build_dist.ps1 (release manifest) and update.ps1 (applying an update).

    python update_helper.py lockinfo <vendor_dir> [<backend_dir>]          -> JSON of lock hashes
    python update_helper.py manifest <root> <version> <min_installer> <installer_schema> <out.json> [--exclude-from-update rel ...]
    python update_helper.py verify <staging_dir> <manifest.json>           -> checks sha256 of every file shipped in the update
    python update_helper.py pipsync <requirements.lock.txt> <bootstrap.lock.txt> [<wheels_dir>]
                                                                           (run with the app's runtime python)
    python update_helper.py mergecfg <user_config.json> <new_default_config.json> <out.json>
    python update_helper.py languagetool <models.lock.json> <backend_dir>

The same hashing code is used when the release is built and when an installed copy is updated, so
"did the requirements / models / LanguageTool lock change?" is answered identically on both sides.
Every hash is computed from file CONTENT (not from the manifest), so installs made before manifests
existed are handled too.
"""
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import time
import urllib.request
import zipfile

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while True:
            b = f.read(4 * 1024 * 1024)
            if not b:
                break
            h.update(b)
    return h.hexdigest()


def sha256_text(s):
    return hashlib.sha256(s.encode("utf-8")).hexdigest()


def norm(n):
    return re.sub(r"[-_.]+", "-", n).lower()


def lock_lines(path):
    if not os.path.isfile(path):
        return []
    out = []
    for line in open(path, encoding="utf-8"):
        line = line.strip()
        if line and not line.startswith("#"):
            out.append(line)
    return sorted(out, key=str.lower)


# ---------------------------------------------------------------------------------------------- lockinfo
def lockinfo(vendor_dir, backend_dir=None):
    info = {}
    info["requirements"] = sha256_text("\n".join(lock_lines(os.path.join(vendor_dir, "requirements.lock.txt"))))
    info["bootstrap"] = sha256_text("\n".join(lock_lines(os.path.join(vendor_dir, "bootstrap.lock.txt"))))
    ml = {}
    p = os.path.join(vendor_dir, "models.lock.json")
    if os.path.isfile(p):
        ml = json.load(open(p, encoding="utf-8"))
    hf = [{"repo_id": e["repo_id"], "cache_subdir": e.get("cache_subdir", ""), "revision": e["revision"],
           "files": sorted([[f["path"], f["size"], f["sha256"]] for f in e["files"]])}
          for e in ml.get("hf", [])]
    hf.sort(key=lambda e: (e["cache_subdir"], e["repo_id"]))
    info["models"] = sha256_text(json.dumps(hf, sort_keys=True))
    lt = ml.get("languagetool")
    info["languagetool"] = sha256_text(json.dumps(lt, sort_keys=True)) if lt else ""
    info["ollama"] = (ml.get("ollama") or {}).get("digest", "")
    info["tatoeba_schema"] = ""
    if backend_dir:
        tb = os.path.join(backend_dir, "tatoeba_build.py")
        if os.path.isfile(tb):
            m = re.search(r'^SCHEMA_VERSION\s*=\s*["\']([^"\']+)["\']', open(tb, encoding="utf-8").read(), re.M)
            if m:
                info["tatoeba_schema"] = m.group(1)
    return info


# ---------------------------------------------------------------------------------------------- manifest
def manifest(root, version, min_installer, installer_schema, out, exclude_from_update):
    files = {}
    for dp, dn, fns in os.walk(root):
        dn.sort()
        for fn in sorted(fns):
            full = os.path.join(dp, fn)
            rel = os.path.relpath(full, root).replace("\\", "/")
            if rel == "manifest.json":
                continue
            files[rel] = {"sha256": sha256_file(full), "size": os.path.getsize(full)}
    excl = [e.replace("\\", "/") for e in exclude_from_update]
    for rel, f in files.items():
        f["in_update"] = not any(rel == e or rel.startswith(e.rstrip("/") + "/") for e in excl)
    m = {
        "version": version,
        "min_installer_version": int(min_installer),
        "installer_version": int(installer_schema),
        "built": time.strftime("%Y-%m-%d %H:%M:%S"),
        "locks": lockinfo(os.path.join(root, "vendor"), os.path.join(root, "backend")),
        "files": files,
    }
    with open(out, "w", encoding="utf-8", newline="\n") as f:
        json.dump(m, f, ensure_ascii=False, indent=1)
    print("manifest: %d files (%d in update), version %s" % (len(files), sum(1 for f in files.values() if f["in_update"]), version))


def verify(staging, manifest_path):
    m = json.load(open(manifest_path, encoding="utf-8"))
    bad = []
    n = 0
    for rel, f in m["files"].items():
        if not f.get("in_update", True):
            continue
        p = os.path.join(staging, *rel.split("/"))
        n += 1
        if not os.path.isfile(p) or os.path.getsize(p) != f["size"] or sha256_file(p) != f["sha256"]:
            bad.append(rel)
    for b in bad:
        print("BAD", b)
    print("VERIFY_RESULT %s (%d files)" % ("OK" if not bad else "FAIL", n))
    return 0 if not bad else 1


# ---------------------------------------------------------------------------------------------- pipsync
def parse_req(lines):
    d = {}
    for line in lines:
        m = re.match(r"^([A-Za-z0-9_.\-]+)\s*(?:==\s*(\S+)|@\s*(\S+))", line)
        if m:
            d[norm(m.group(1))] = (m.group(2) or m.group(3).split("#")[0], line)
    return d


def pip(args, check=True):
    cmd = [sys.executable, "-X", "utf8", "-m", "pip"] + args
    print("> pip " + " ".join(args), flush=True)
    if os.environ.get("HOEHWA_PIP_DRYRUN") == "1":
        print("  (dry run: not executed)", flush=True)
        return 0
    r = subprocess.call(cmd)
    if check and r != 0:
        raise SystemExit("pip failed (exit %d)" % r)
    return r


def pipsync(lock, boot, wheels):
    env_ok = True
    os.environ["PIP_DISABLE_PIP_VERSION_CHECK"] = "1"
    os.environ["PIP_NO_INPUT"] = "1"
    # 1. pip / setuptools pins
    want_boot = parse_req(lock_lines(boot))
    r = subprocess.run([sys.executable, "-X", "utf8", "-m", "pip", "list", "--format=freeze"],
                       stdout=subprocess.PIPE, text=True, encoding="utf-8", errors="replace")
    have_all = parse_req(r.stdout.splitlines())
    boot_todo = [line for k, (v, line) in want_boot.items() if have_all.get(k, (None,))[0] != v]
    if boot_todo:
        pip(["install", "--no-warn-script-location", "--disable-pip-version-check"] + boot_todo)
    # 2. app packages: only what differs from the lock
    want = parse_req(lock_lines(lock))
    r = subprocess.run([sys.executable, "-X", "utf8", "-m", "pip", "freeze"],
                       stdout=subprocess.PIPE, text=True, encoding="utf-8", errors="replace")
    have = parse_req(r.stdout.splitlines())
    todo = [line for k, (v, line) in sorted(want.items()) if k not in have or have[k][0] != v]
    extra = [k for k in sorted(have) if k not in want and k not in ("pip", "setuptools", "wheel")]
    print("PIPSYNC plan: install/upgrade %d, remove %d" % (len(todo), len(extra)), flush=True)
    for t in todo:
        print("  + " + t, flush=True)
    for e in extra:
        print("  - " + e, flush=True)
    if extra:
        pip(["uninstall", "-y"] + extra)
    if todo:
        args = ["install", "--no-deps", "--no-warn-script-location", "--progress-bar", "off", "--disable-pip-version-check"]
        if wheels and os.path.isdir(wheels):
            args += ["--find-links", wheels]
        if any("+cpu" in t for t in todo):
            args += ["--extra-index-url", "https://download.pytorch.org/whl/cpu"]
        tmp = os.path.join(os.path.dirname(os.path.abspath(lock)), "_pipsync_todo.txt")
        with open(tmp, "w", encoding="utf-8") as f:
            f.write("\n".join(todo) + "\n")
        try:
            pip(args + ["-r", tmp])
        finally:
            try:
                os.remove(tmp)
            except OSError:
                pass
    if os.environ.get("HOEHWA_PIP_DRYRUN") == "1":
        print("PIPSYNC_RESULT DRYRUN")
        return 0
    # 3. verify
    r = subprocess.run([sys.executable, "-X", "utf8", "-m", "pip", "freeze"],
                       stdout=subprocess.PIPE, text=True, encoding="utf-8", errors="replace")
    have = parse_req(r.stdout.splitlines())
    diff = sorted(set(k for k in want if k not in have or have[k][0] != want[k][0]) |
                  set(k for k in have if k not in want))
    for k in diff:
        print("  MISMATCH %s: want %s have %s" % (k, want.get(k, ("-",))[0], have.get(k, ("-",))[0]))
    print("PIPSYNC_RESULT %s" % ("OK" if not diff else "MISMATCH"))
    return 0 if not diff else 1


# ---------------------------------------------------------------------------------------------- config merge
def merge(default, user):
    """new defaults + every value the user/installer already had (user wins, nested dicts merged)"""
    if isinstance(default, dict) and isinstance(user, dict):
        out = dict(default)
        for k, v in user.items():
            out[k] = merge(default[k], v) if k in default else v
        return out
    return user


def mergecfg(user_path, new_path, out_path):
    new = json.load(open(new_path, encoding="utf-8"))
    user = json.load(open(user_path, encoding="utf-8")) if os.path.isfile(user_path) else {}
    res = merge(new, user)
    added = [k for k in new if k not in user]
    tmp = out_path + ".tmp"
    with open(tmp, "w", encoding="utf-8", newline="\n") as f:
        json.dump(res, f, ensure_ascii=False, indent=2)
    os.replace(tmp, out_path)
    print("config merged: kept %d user keys, added %s" % (len(user), ", ".join(added) or "nothing"))


# ---------------------------------------------------------------------------------------------- LanguageTool
def languagetool(lock_path, backend):
    lt = json.load(open(lock_path, encoding="utf-8")).get("languagetool")
    if not lt:
        print("LT_RESULT SKIP (no entry)")
        return 0
    root = os.path.join(backend, "tools", "languagetool")
    jar = os.path.join(root, lt["dir"], "languagetool-server.jar")
    man = os.path.join(root, "lt.json")
    if os.path.isfile(jar) and os.path.isfile(man):
        try:
            if json.load(open(man, encoding="utf-8")).get("sha256") == lt["sha256"]:
                print("LT_RESULT OK (already %s)" % lt["version"])
                return 0
        except Exception:
            pass
    os.makedirs(root, exist_ok=True)
    zpath = os.path.join(root, "_download.zip")
    print("downloading %s (%.0f MB)" % (lt["url"], lt["size"] / 1e6), flush=True)
    urllib.request.urlretrieve(lt["url"], zpath)
    if os.path.getsize(zpath) != lt["size"] or sha256_file(zpath) != lt["sha256"]:
        os.remove(zpath)
        print("LT_RESULT FAIL (sha256 mismatch)")
        return 1
    tmp = os.path.join(root, "_extract")
    shutil.rmtree(tmp, ignore_errors=True)
    with zipfile.ZipFile(zpath) as z:
        z.extractall(tmp)
    dst = os.path.join(root, lt["dir"])
    shutil.rmtree(dst, ignore_errors=True)
    shutil.move(os.path.join(tmp, lt["dir"]), dst)
    shutil.rmtree(tmp, ignore_errors=True)
    os.remove(zpath)
    with open(man, "w", encoding="utf-8") as f:
        json.dump({k: lt[k] for k in ("version", "dir", "url", "sha256", "size")}, f, indent=2)
    print("LT_RESULT OK (installed %s)" % lt["version"])
    return 0


def main():
    a = sys.argv[1:]
    if not a:
        print(__doc__)
        return 2
    cmd = a[0]
    if cmd == "lockinfo":
        print(json.dumps(lockinfo(a[1], a[2] if len(a) > 2 else None)))
        return 0
    if cmd == "manifest":
        excl = []
        if "--exclude-from-update" in a:
            i = a.index("--exclude-from-update")
            excl, a = a[i + 1:], a[:i]
        manifest(a[1], a[2], a[3], a[4], a[5], excl)
        return 0
    if cmd == "verify":
        return verify(a[1], a[2])
    if cmd == "pipsync":
        return pipsync(a[1], a[2], a[3] if len(a) > 3 else None)
    if cmd == "mergecfg":
        mergecfg(a[1], a[2], a[3])
        return 0
    if cmd == "languagetool":
        return languagetool(a[1], a[2])
    print("unknown command", cmd)
    return 2


if __name__ == "__main__":
    sys.exit(main())
