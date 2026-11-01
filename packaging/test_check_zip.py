# -*- coding: utf-8 -*-
"""Tests packaging/check_zip.py: a clean package passes, every deliberately polluted copy fails.

    python -X utf8 packaging/test_check_zip.py [<update or payload zip>]

Without an argument a small clean update-style zip is built in a temp folder (manifest, vendor files, default config, sanitized prefs),
so the test needs no build. With an argument that zip is used as the clean base (e.g. packaging/out/release_<v>/hoehwa-practice-update-<v>.zip).
Everything is written to a temp folder that is removed at the end. Last line: CHECK_ZIP_TEST OK (exit 0) or CHECK_ZIP_TEST FAIL <n> (exit 1).
"""
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
CHECK = os.path.join(HERE, "check_zip.py")
CFG = os.path.join(HERE, "defaults", "config.default.json")
TMP = tempfile.mkdtemp(prefix="hoehwa-checkzip-test-")
RESULTS = []


def clean_files():
    """Files of a minimal, clean update-style package (zip root = app root)."""
    man = {
        "version": "9.9.9", "min_installer_version": 1, "installer_version": 2,
        "files": {"vendor/install_tools.py": {"sha256": "0" * 64, "size": 1, "in_update": True}},
    }
    return {
        "manifest.json": json.dumps(man).encode("utf-8"),
        "stop_app.ps1": b"# stop\n",
        "install.ps1": b"# install\n",
        "vendor/install_tools.py": b"# tools\n",
        "vendor/tools.lock.json": b"{}",
        "vendor/update_helper.py": b"# helper\n",
        "backend/server.py": b"# server\n",
        "backend/config.json": open(CFG, "rb").read(),
        "defaults/prefs.json": json.dumps({"lang": "en", "tts_speed": 1.0}).encode("utf-8"),
    }


def read_zip(path):
    z = zipfile.ZipFile(path)
    return {i.filename: z.read(i) for i in z.infolist() if not i.filename.endswith("/")}


def write_zip(name, files):
    out = os.path.join(TMP, re.sub(r"[^A-Za-z0-9_.-]", "_", name) + ".zip")
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        for n, b in files.items():
            z.writestr(n, b)
    return out


def run(z):
    r = subprocess.run([sys.executable, "-X", "utf8", CHECK, z, CFG], capture_output=True, text=True, encoding="utf-8")
    return r.returncode, r.stdout


BASE = None


def expect(name, edit, want_fail, needle=""):
    files = dict(BASE)
    edit(files)
    code, out = run(write_zip(name, files))
    ok = (code != 0) if want_fail else (code == 0)
    if want_fail and needle:
        ok = ok and needle in out
    RESULTS.append(ok)
    last = out.strip().splitlines()[-1] if out.strip() else ""
    print(("PASS " if ok else "FAIL ") + name + " | exit=%d | %s" % (code, last.replace(TMP, "<tmp>")[:110]))


def add(n, b=b"x"):
    return lambda files: files.__setitem__(n, b)


def drop(n):
    return lambda files: files.pop(n)


def man_edit(fn):
    def f(files):
        m = json.loads(files["manifest.json"].decode("utf-8"))
        fn(m)
        files["manifest.json"] = json.dumps(m).encode("utf-8")
    return f


def set_prefs(d):
    return lambda files: files.__setitem__("defaults/prefs.json", json.dumps(d).encode("utf-8"))


try:
    if len(sys.argv) > 1:
        BASE = read_zip(sys.argv[1])
        print("base: %s (%d files)" % (sys.argv[1], len(BASE)))
    else:
        BASE = clean_files()
    expect("clean package", lambda f: None, False)
    expect("secrets.json added", add("backend/secrets.json"), True, "secrets.json")
    expect("progress.json added", add("defaults/progress.json"), True, "learning history")
    expect("test_x.py added", add("backend/test_x.py"), True, "test file")
    expect("auth.json added", add("auth.json"), True, "credentials")
    expect("song lyrics file added", add("songs/x/song.json"), True, "song")
    expect("audio file added", add("backend/x.mp3"), True, "audio")
    expect("config.json is not the default", add("backend/config.json", b'{"port": 1}'), True, "config.json")
    expect("prefs.json has lesson_cursor", set_prefs({"lang": "en", "lesson_cursor": {"en-1-1": 3}}), True, "lesson_cursor")
    expect("prefs.json has mic_device", set_prefs({"mic_device": "x"}), True, "mic_device")
    expect("prefs.json has a *_consent choice", set_prefs({"song_consent": True}), True, "consent")
    expect("manifest without version", man_edit(lambda m: m.pop("version")), True, "version")
    expect("manifest version 'abc'", man_edit(lambda m: m.update(version="abc")), True, "version")
    expect("manifest without installer_version", man_edit(lambda m: m.pop("installer_version")), True, "installer_version")
    expect("vendor/install_tools.py missing", drop("vendor/install_tools.py"), True, "install_tools.py")
    expect("vendor/tools.lock.json missing", drop("vendor/tools.lock.json"), True, "tools.lock.json")
    expect("stop_app.ps1 missing", drop("stop_app.ps1"), True, "stop_app.ps1")
    expect("unsafe entry name (..)", add("../evil.txt"), True, "unsafe")
finally:
    shutil.rmtree(TMP, ignore_errors=True)
bad = RESULTS.count(False)
print("CHECK_ZIP_TEST %s (%d cases)" % ("OK" if bad == 0 else "FAIL %d" % bad, len(RESULTS)))
sys.exit(0 if bad == 0 else 1)
