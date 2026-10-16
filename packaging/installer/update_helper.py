# -*- coding: utf-8 -*-
"""Helper for build_dist.ps1 (release manifest) and update.ps1 (applying an update).

    python update_helper.py lockinfo <vendor_dir> [<backend_dir>]          -> JSON of lock hashes
    python update_helper.py manifest <root> <version> <min_installer> <installer_schema> <out.json> [--exclude-from-update rel ...]
    python update_helper.py verify <staging_dir> <manifest.json>           -> checks sha256 of every file shipped in the update
    python update_helper.py pipsync <requirements.lock.txt> <bootstrap.lock.txt> [<wheels_dir>]
                                                                           (run with the app's runtime python)
    python update_helper.py mergecfg <user_config.json> <new_default_config.json> <out.json>
    python update_helper.py languagetool <models.lock.json> <backend_dir>
    python update_helper.py dirsize <root> [--skip rel ...]                -> total bytes of a folder tree
    python update_helper.py prunehf <models.lock.json> <hf_dir> [--old-lock <previous models.lock.json>] [--apply]
                                                                           -> list (and with --apply delete) model files the PREVIOUS lock installed and the new lock no
                                                                              longer uses (+ the installer's download caches). Files the lock never listed are the user's: never touched.
    python update_helper.py refsave <hf_dir> <out.json>                    -> remember every refs/* file of the model caches (before an update changes them)
    python update_helper.py refrestore <saved.json> <hf_dir>               -> put those refs back (rollback)
    python update_helper.py setcfg <config.json> <key> <value>             -> sets one top-level string value

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

# Test hooks (HOEHWA_*) only work when HOEHWA_TEST_MODE=1 is set explicitly; a shipped install ignores them.
TEST_MODE = os.environ.get("HOEHWA_TEST_MODE") == "1"

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


# user data / installed components that an update package may never write to
PROTECTED_PREFIXES = ("runtime/", "backup/", "backend/models/", "backend/data/", "backend/cache/", "backend/logs/",
                      "backend/tools/", "backend/.venv/")
PROTECTED_FILES = ("version.txt", "install.log", "update.log")


def unsafe_reason(rel, for_update=True):
    """Why a manifest path must not be used, or None when it is a plain relative path inside the app folder."""
    if not isinstance(rel, str) or not rel.strip():
        return "empty path"
    if rel.startswith(("/", "\\")) or re.match(r"^[A-Za-z]:", rel):
        return "absolute path or drive letter"
    if ":" in rel or "\\" in rel or any(ord(c) < 32 or c in '*?"<>|' for c in rel):
        return "illegal character"
    for seg in rel.split("/"):
        if seg in ("", ".", ".."):
            return "'..' or empty path segment"
        if seg.endswith((".", " ")):
            return "segment ends with dot or space"
    if for_update:
        low = rel.lower()
        if low.startswith(PROTECTED_PREFIXES) or low in PROTECTED_FILES or re.match(r"^backend/secrets\.json", low):
            return "protected location"
    return None


def verify(staging, manifest_path):
    m = json.load(open(manifest_path, encoding="utf-8"))
    bad = []
    n = 0
    root = os.path.abspath(staging)
    for rel, f in m["files"].items():
        in_update = f.get("in_update", True)
        why = unsafe_reason(rel, for_update=in_update)
        if why:
            print("BADPATH %r: %s" % (rel, why))
            bad.append(rel)
            continue
        if not in_update:
            continue
        p = os.path.abspath(os.path.join(staging, *rel.split("/")))
        if os.path.commonpath([root, p]) != root:
            print("BADPATH %r: outside the update folder" % rel)
            bad.append(rel)
            continue
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
    if (TEST_MODE and os.environ.get("HOEHWA_PIP_DRYRUN") == "1"):
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
    os.environ["PIP_NO_CACHE_DIR"] = "1"   # nothing is cached: "updating should not grow the app"
    # 1. pip / setuptools pins
    want_boot = parse_req(lock_lines(boot))
    r = subprocess.run([sys.executable, "-X", "utf8", "-m", "pip", "list", "--format=freeze"],
                       stdout=subprocess.PIPE, text=True, encoding="utf-8", errors="replace")
    have_all = parse_req(r.stdout.splitlines())
    boot_todo = [line for k, (v, line) in want_boot.items() if have_all.get(k, (None,))[0] != v]
    if boot_todo:
        pip(["install", "--no-cache-dir", "--no-warn-script-location", "--disable-pip-version-check"] + boot_todo)
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
        args = ["install", "--no-deps", "--no-cache-dir", "--no-warn-script-location", "--progress-bar", "off", "--disable-pip-version-check"]
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
    if (TEST_MODE and os.environ.get("HOEHWA_PIP_DRYRUN") == "1"):
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
    new = json.load(open(new_path, encoding="utf-8-sig"))
    user = json.load(open(user_path, encoding="utf-8-sig")) if os.path.isfile(user_path) else {}
    res = merge(new, user)
    added = [k for k in new if k not in user]
    tmp = out_path + ".tmp"
    with open(tmp, "w", encoding="utf-8", newline="\n") as f:
        json.dump(res, f, ensure_ascii=False, indent=2)
    os.replace(tmp, out_path)
    print("config merged: kept %d user keys, added %s" % (len(user), ", ".join(added) or "nothing"))


def setcfg(path, key, value):
    cfg = json.load(open(path, encoding="utf-8-sig"))
    cfg[key] = value
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8", newline="\n") as f:
        json.dump(cfg, f, ensure_ascii=False, indent=2)
    os.replace(tmp, path)
    print("config: %s = %s" % (key, value))


# ---------------------------------------------------------------------------------------------- folder size
def dirsize(root, skips=()):
    """Total bytes of all files below root (symlinks are not followed). `skips` are folders (relative to root) to leave out."""
    root = os.path.abspath(root)
    skip = set(os.path.normcase(os.path.abspath(os.path.join(root, s))) for s in skips)
    total = 0
    stack = [root]
    while stack:
        d = stack.pop()
        if os.path.normcase(d) in skip:
            continue
        try:
            with os.scandir(("\\\\?\\" + d) if os.name == "nt" and not d.startswith("\\\\?\\") else d) as it:
                for e in it:
                    try:
                        if e.is_symlink():
                            continue
                        if e.is_dir(follow_symlinks=False):
                            stack.append(os.path.join(d, e.name))
                        elif e.is_file(follow_symlinks=False):
                            total += e.stat(follow_symlinks=False).st_size
                    except OSError:
                        pass
        except OSError:
            pass
    return total


# ---------------------------------------------------------------------------------------------- model cleanup
def _tree_bytes(path):
    if os.path.islink(path) or os.path.isfile(path):
        try:
            return os.lstat(path).st_size
        except OSError:
            return 0
    return dirsize(path)


def _rm_path(path):
    """Delete a file, a symlink (never its target) or a folder tree."""
    if os.path.islink(path):
        try:
            os.unlink(path)
        except OSError:
            os.rmdir(path)
        return
    if os.path.isdir(path):
        def onerr(func, p, exc):
            os.chmod(p, 0o700)
            func(p)
        shutil.rmtree(path, onerror=onerr)
    else:
        try:
            os.remove(path)
        except PermissionError:
            os.chmod(path, 0o700)
            os.remove(path)


def _hf_scan(hf):
    """(repo folders, download-cache folders) of an hf folder: models--* live in hf itself and in its direct sub folders (cache_subdir, e.g. "whisper")."""
    repos, cache_dirs = [], []
    scan = [hf] + [os.path.join(hf, d) for d in sorted(os.listdir(hf))
                   if os.path.isdir(os.path.join(hf, d)) and not os.path.islink(os.path.join(hf, d))
                   and not d.startswith("models--") and d not in ("xet", ".locks")]
    for d in scan:
        for name in sorted(os.listdir(d)):
            full = os.path.join(d, name)
            if name.startswith("models--"):
                repos.append(full)
            elif name in ("xet", ".locks"):
                cache_dirs.append(full)
    return repos, cache_dirs


def _entry_key(hf, e):
    base = os.path.join(hf, e.get("cache_subdir") or "")
    return os.path.normcase(os.path.abspath(os.path.join(base, "models--" + e["repo_id"].replace("/", "--"))))


def prunehf(lock_path, hf_dir, apply=False, old_lock_path=None):
    """Deletes model files that the app itself installed and no longer needs - nothing else, and nothing outside hf_dir.
       "Installed by the app" means: listed in the PREVIOUS models.lock.json (old_lock_path, copied before the update replaced it).
       Anything no lock file ever listed (a voice pack or file the user added, a model repo the user downloaded) is the user's
       and is left alone, even inside a repo folder the lock covers.
       - files of the previous lock that the new lock does not list (or whose revision changed), and the blobs only they used
       - trees/<previous revision>.json; a repo the new lock dropped is removed completely once none of the user's files remain in it
       - download caches (xet, .locks) that only the installer needs (these are always the app's own)
       Without old_lock_path (install.ps1) only the download caches are removed.
       The plan is always printed first; files are removed only with apply=True."""
    lock = json.load(open(lock_path, encoding="utf-8-sig"))
    entries = lock.get("hf") or []
    if not entries:
        print("PRUNE_RESULT SKIP (lock lists no models)")
        return 0
    hf = os.path.abspath(hf_dir)
    if not os.path.isdir(hf):
        print("PRUNE_RESULT SKIP (no model folder)")
        return 0
    hf_n = os.path.normcase(os.path.realpath(hf))
    old_entries = []
    if old_lock_path:
        try:
            old_entries = json.load(open(old_lock_path, encoding="utf-8-sig")).get("hf") or []
        except (OSError, ValueError) as ex:
            print("PRUNE note: previous lock unreadable (%s) -> model files are kept, only download caches are removed" % ex)
    else:
        print("PRUNE note: no previous lock given -> model files are kept, only download caches are removed")

    def inside(path):
        p = os.path.normcase(os.path.realpath(os.path.dirname(path) if os.path.islink(path) else path))
        return p != hf_n and p.startswith(hf_n + os.sep)

    new_by_path = {_entry_key(hf, e): e for e in entries}
    plan = []   # (path, bytes, why)
    touched = []

    def add(path, why):
        plan.append((path, _tree_bytes(path), why))

    repos, cache_dirs = _hf_scan(hf)
    repo_by_key = {os.path.normcase(os.path.abspath(r)): r for r in repos}
    for oe in old_entries:
        key = _entry_key(hf, oe)
        full = repo_by_key.get(key)
        if full is None or os.path.islink(full):
            continue
        ne = new_by_path.get(key)
        same_rev = ne is not None and ne["revision"] == oe["revision"]
        new_paths = set(f["path"].replace("\\", "/") for f in ne["files"]) if ne is not None else set()
        # (revision, relative path) of everything some lock lists = what the app put there
        listed = set((oe["revision"], f["path"].replace("\\", "/")) for f in oe["files"])
        if ne is not None:
            listed |= set((ne["revision"], f["path"].replace("\\", "/")) for f in ne["files"])
        snaps = os.path.join(full, "snapshots")
        sp = os.path.join(snaps, oe["revision"])
        mine = []     # (file path, sha256) the previous lock installed and the new lock does not need
        for f in oe["files"]:
            rel = f["path"].replace("\\", "/")
            if same_rev and rel in new_paths:
                continue
            fp = os.path.join(sp, *rel.split("/"))
            if os.path.lexists(fp):
                mine.append((fp, f["sha256"]))
        planned = set(os.path.normcase(os.path.abspath(fp)) for fp, _ in mine)
        # what stays behind in the snapshots: files the new lock still uses, and the user's own files
        user_files = []
        referenced = set(f["sha256"] for f in ne["files"]) if ne is not None else set()
        if os.path.isdir(snaps):
            for dp, dn, fns in os.walk(snaps):
                parts = os.path.relpath(dp, snaps).replace("\\", "/").split("/")
                rev = parts[0] if parts[0] != "." else ""
                sub = "/".join(parts[1:])
                for fn in fns:
                    fp = os.path.join(dp, fn)
                    if os.path.normcase(os.path.abspath(fp)) in planned:
                        continue
                    if os.path.islink(fp):
                        referenced.add(os.path.basename(os.path.realpath(fp)))
                    if (rev, (sub + "/" + fn) if sub else fn) not in listed:
                        user_files.append(fp)
        if ne is None and not user_files:
            add(full, "repo dropped from the lock (installed by the app; none of your files in it)")
            touched.append(full)
            continue
        for fp, _ in mine:
            add(fp, "file the app installed, not used any more")
        blobs = os.path.join(full, "blobs")
        cand = set(sha for _, sha in mine)
        for fp, _ in mine:
            if os.path.islink(fp):
                cand.add(os.path.basename(os.path.realpath(fp)))
        if os.path.isdir(blobs):
            for b in sorted(cand):
                if b not in referenced and os.path.lexists(os.path.join(blobs, b)):
                    add(os.path.join(blobs, b), "blob only those files used")
        if not same_rev:
            t = os.path.join(full, "trees", oe["revision"] + ".json")
            if os.path.lexists(t):
                add(t, "tree of the previous revision")
        for u in user_files:
            print("PRUNE keep %s [not installed by the app]" % os.path.relpath(u, hf), flush=True)
        touched.append(full)
    for c in cache_dirs:
        add(c, "download cache")

    total = sum(b for _, b, _ in plan)
    for path, b, why in plan:
        print("PRUNE %s %s (%.1f MB) [%s]" % ("delete" if apply else "would delete", os.path.relpath(path, hf), b / 1e6, why), flush=True)
    if not apply:
        print("PRUNE_RESULT DRYRUN (%d items, %.1f MB)" % (len(plan), total / 1e6))
        return 0
    errors = 0
    for path, b, why in plan:
        if not inside(path):
            print("PRUNE refused (outside the model folder): %s" % path)
            errors += 1
            continue
        try:
            _rm_path(path)
        except OSError as ex:
            print("PRUNE error %s: %s" % (os.path.relpath(path, hf), ex))
            errors += 1
    # remove sub folders the deletions emptied (never a folder that still holds a file)
    for full in touched:
        if not os.path.isdir(full):
            continue
        for dp, dn, fns in os.walk(full, topdown=False):
            if dp != full and not os.path.islink(dp) and not os.listdir(dp):
                try:
                    os.rmdir(dp)
                except OSError:
                    pass
    print("PRUNE_RESULT %s (deleted %d items, %.1f MB)" % ("OK" if not errors else "ERRORS %d" % errors, len(plan) - errors, total / 1e6))
    return 0


# ---------------------------------------------------------------------------------------------- refs/main save / restore
def _ref_files(hf):
    """{path relative to hf: absolute path} of every file in refs/ of every model repo below hf."""
    out = {}
    repos, _ = _hf_scan(hf)
    for full in repos:
        for dp, dn, fns in os.walk(os.path.join(full, "refs")):
            for fn in fns:
                p = os.path.join(dp, fn)
                out[os.path.relpath(p, hf).replace("\\", "/")] = p
    return out


def refsave(hf_dir, out_path):
    """Remembers refs/main (and any other refs/*) of every model cache exactly as it is now."""
    hf = os.path.abspath(hf_dir)
    saved = {"refs": {}}
    if os.path.isdir(hf):
        for rel, p in _ref_files(hf).items():
            with open(p, "rb") as f:
                saved["refs"][rel] = f.read().decode("utf-8", "surrogateescape")
    tmp = out_path + ".tmp"
    with open(tmp, "w", encoding="utf-8", newline="\n") as f:
        json.dump(saved, f, ensure_ascii=True, indent=1)
    os.replace(tmp, out_path)
    print("REFSAVE_RESULT OK (%d refs)" % len(saved["refs"]))
    return 0


def refrestore(saved_path, hf_dir):
    """Puts the refs back as refsave saw them: changed ones get their old content back, ones that did not exist before are removed."""
    try:
        saved = json.load(open(saved_path, encoding="utf-8"))
    except (OSError, ValueError) as ex:
        print("REFRESTORE_RESULT REFUSED (saved file unreadable: %s) - nothing changed" % ex)
        return 1
    if not isinstance(saved, dict) or not isinstance(saved.get("refs"), dict):
        print("REFRESTORE_RESULT REFUSED (saved file has no valid 'refs' dict) - nothing changed")
        return 1
    hf = os.path.abspath(hf_dir)
    hf_n = os.path.normcase(os.path.realpath(hf))
    restored = removed = errors = 0
    now = _ref_files(hf) if os.path.isdir(hf) else {}
    if not saved["refs"] and now:
        # refsave never writes an empty list while refs exist; an empty dict here would delete every current ref
        print("REFRESTORE_RESULT REFUSED (saved refs are empty but %d refs exist now) - nothing changed" % len(now))
        return 1
    for rel, text in saved["refs"].items():
        p = os.path.abspath(os.path.join(hf, *rel.split("/")))
        if not os.path.normcase(os.path.realpath(p)).startswith(hf_n + os.sep):
            print("REFRESTORE refused (outside the model folder): %s" % rel)
            errors += 1
            continue
        data = text.encode("utf-8", "surrogateescape")
        try:
            if os.path.isfile(p):
                with open(p, "rb") as f:
                    if f.read() == data:
                        continue
            os.makedirs(os.path.dirname(p), exist_ok=True)
            with open(p, "wb") as f:
                f.write(data)
            restored += 1
            print("REFRESTORE %s restored" % rel)
        except OSError as ex:
            print("REFRESTORE error %s: %s" % (rel, ex))
            errors += 1
    for rel, p in now.items():
        if rel not in saved["refs"]:
            try:
                os.remove(p)
                removed += 1
                print("REFRESTORE %s removed (did not exist before)" % rel)
            except OSError as ex:
                print("REFRESTORE error %s: %s" % (rel, ex))
                errors += 1
    print("REFRESTORE_RESULT %s (restored %d, removed %d)" % ("OK" if not errors else "ERRORS %d" % errors, restored, removed))
    return 0 if not errors else 1


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
    tmp = os.path.join(root, "_extract")
    try:
        print("downloading %s (%.0f MB)" % (lt["url"], lt["size"] / 1e6), flush=True)
        urllib.request.urlretrieve(lt["url"], zpath)
        if os.path.getsize(zpath) != lt["size"] or sha256_file(zpath) != lt["sha256"]:
            print("LT_RESULT FAIL (sha256 mismatch)")
            return 1
        shutil.rmtree(tmp, ignore_errors=True)
        with zipfile.ZipFile(zpath) as z:
            z.extractall(tmp)
        dst = os.path.join(root, lt["dir"])
        shutil.rmtree(dst, ignore_errors=True)
        shutil.move(os.path.join(tmp, lt["dir"]), dst)
    finally:
        # success or failure (download error, bad hash, broken zip, Ctrl+C): no leftover download or extract folder
        shutil.rmtree(tmp, ignore_errors=True)
        try:
            os.remove(zpath)
        except OSError:
            pass
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
    if cmd == "dirsize":
        skips = []
        if "--skip" in a:
            i = a.index("--skip")
            skips, a = a[i + 1:], a[:i]
        print(dirsize(a[1], skips))
        return 0
    if cmd == "prunehf":
        old_lock = a[a.index("--old-lock") + 1] if "--old-lock" in a else None
        return prunehf(a[1], a[2], "--apply" in a, old_lock)
    if cmd == "refsave":
        return refsave(a[1], a[2])
    if cmd == "refrestore":
        return refrestore(a[1], a[2])
    if cmd == "setcfg":
        setcfg(a[1], a[2], a[3])
        return 0
    print("unknown command", cmd)
    return 2


if __name__ == "__main__":
    sys.exit(main())
