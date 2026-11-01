# -*- coding: utf-8 -*-
"""Tests for packaging/installer/install_tools.py (no network: archives are built here and served via file:///).

    python -I -X utf8 packaging\\test_install_tools.py        -> last line: INSTALL_TOOLS_TEST PASS n/n   (exit 0)

Every "bad input" case must FAIL for the right reason (exit code, FAIL kind, nothing left behind) -- a tool that
only passes on good input is not trusted. Temp files go to the system temp folder (set TEMP to redirect).
"""
import hashlib
import sys
sys.dont_write_bytecode = True
import json
import os
import shutil
import subprocess
import sys
import tempfile
import traceback
import urllib.error
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
TOOL = os.path.join(HERE, "installer", "install_tools.py")
REAL_LOCK = os.path.join(HERE, "tools.lock.json")
ROOT = tempfile.mkdtemp(prefix="hoehwa_it_")

results = []


def sha(p):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        h.update(f.read())
    return h.hexdigest()


def make_zip(path, entries):
    """entries: list of (name, bytes) -- names are written verbatim (zip-slip names included)."""
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as z:
        for name, data in entries:
            z.writestr(name, data)


def file_url(p):
    return "file:///" + os.path.abspath(p).replace("\\", "/")


def new_case(name):
    d = os.path.join(ROOT, name)
    os.makedirs(d)
    return d


def write_lock(case, oc_zip, jre_zip, oc_ver="1.19.0", mutate=None, base_zip=None):
    """Lock file pointing at local zips. `mutate(lock_dict)` can tamper with it."""
    oc_base = base_zip or oc_zip
    lock = {
        "schema": 1,
        "opencode": {
            "version": oc_ver, "dest": "backend/tools/opencode", "exe": "opencode.exe",
            "variants": {
                "x64": {"url": file_url(oc_zip), "sha256": sha(oc_zip), "size": os.path.getsize(oc_zip)},
                "x64-baseline": {"url": file_url(oc_base), "sha256": sha(oc_base), "size": os.path.getsize(oc_base)},
            },
        },
        "jre": {"version": "21.0.13+9", "dest": "backend/tools", "url": file_url(jre_zip), "sha256": sha(jre_zip),
                "size": os.path.getsize(jre_zip)},
    }
    if mutate:
        mutate(lock)
    p = os.path.join(case, "lock.json")
    with open(p, "w", encoding="utf-8") as f:
        json.dump(lock, f)
    return p


def good_zips(case, tag=b"v1"):
    oc = os.path.join(case, "oc.zip")
    jre = os.path.join(case, "jre.zip")
    make_zip(oc, [("opencode.exe", b"MZ-fake-opencode-" + tag)])
    make_zip(jre, [("jdk-21.0.13+9-jre/bin/java.exe", b"MZ-fake-java"), ("jdk-21.0.13+9-jre/release", b"x")])
    return oc, jre


def run(lock, app, args=(), env_extra=None, test_mode=True, stdin_null=True):
    env = dict(os.environ)
    env.pop("HOEHWA_TEST_MODE", None)
    if test_mode:
        env["HOEHWA_TEST_MODE"] = "1"
    env.update(env_extra or {})
    p = subprocess.run([sys.executable, "-I", "-X", "utf8", TOOL, lock, app] + list(args), env=env,
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL if stdin_null else None)
    return p.returncode, p.stdout.decode("utf-8", "replace")


def leftovers(app):
    """Names of dl / .part / .new / .old leftovers under app."""
    bad = []
    for dp, dn, fn in os.walk(app):
        for n in dn + fn:
            if n == "dl" or n.endswith((".part", ".new", ".new2", ".old")):
                bad.append(os.path.join(dp, n))
    return bad


def tree(base):
    out = []
    for dp, dn, fn in os.walk(base):
        for n in fn:
            out.append(os.path.join(dp, n))
    return out


def check(cond, msg):
    if not cond:
        raise AssertionError(msg)


def test(fn):
    name = fn.__name__
    try:
        fn()
        results.append((name, True, ""))
        print("  ok   %s" % name)
    except Exception as e:
        results.append((name, False, "%s: %s" % (type(e).__name__, e)))
        print("  FAIL %s -> %s" % (name, e))
        if not isinstance(e, AssertionError):
            traceback.print_exc()
    return fn


# ------------------------------------------------------------------------------------------------ tests
@test
def t_a1_real_lock_values():
    d = json.load(open(REAL_LOCK, encoding="utf-8"))
    o = d["opencode"]
    check(o["version"] == "1.19.0", "version")
    check(o["variants"]["x64"]["sha256"] == "17108e9448c4fdad48eb8714c4ed6f5dfc9cf86c2eb8f2ce5d02043fef806eb5", "x64")
    check(o["variants"]["x64-baseline"]["sha256"] == "2759ca3449fe946d82da3be43d2e85332127399686aafceaff153b90c3079c56", "baseline")
    check(d["jre"]["sha256"] == "2332c0b4cff6bed722da3567c91d5e47568bcba863fa4945d0a8d6fc76158628", "jre")
    check(d["buildtools"]["innosetup"]["sha256"] == "a549929319f9120716677c685535ca4671e4b937b5fdc87e2585f32d8eb30e8c", "inno")
    for u in (o["variants"]["x64"]["url"], o["variants"]["x64-baseline"]["url"], d["jre"]["url"], d["buildtools"]["innosetup"]["url"]):
        check(u.startswith("https://"), "https only: " + u)


@test
def t_good_install_both():
    c = new_case("good")
    oc, jre = good_zips(c)
    lock = write_lock(c, oc, jre)
    app = os.path.join(c, "app")
    rc, out = run(lock, app, ["--progress-file", os.path.join(c, "prog.json")])
    check(rc == 0, "exit %s\n%s" % (rc, out))
    check("TOOL opencode OK 1.19.0" in out and "TOOL jre OK 21.0.13+9" in out and out.strip().endswith("TOOL_RESULT OK"), out)
    check(os.path.isfile(os.path.join(app, "backend", "tools", "opencode", "opencode.exe")), "opencode.exe")
    check(os.path.isfile(os.path.join(app, "backend", "tools", "jdk-21.0.13+9-jre", "bin", "java.exe")), "java.exe")
    tj = json.load(open(os.path.join(app, "backend", "tools", "opencode", "tool.json"), encoding="utf-8"))
    check(tj["version"] == "1.19.0" and tj["sha256"] == sha(oc), "tool.json " + str(tj))
    check(not leftovers(app), "leftovers %s" % leftovers(app))
    pr = json.load(open(os.path.join(c, "prog.json"), encoding="utf-8"))
    check(pr["pct"] == 100, "progress " + str(pr))


@test
def t_only_flag():
    c = new_case("only")
    oc, jre = good_zips(c)
    lock = write_lock(c, oc, jre)
    app = os.path.join(c, "app")
    rc, out = run(lock, app, ["--only", "jre"])
    check(rc == 0 and "TOOL jre OK" in out and "opencode" not in out.replace("TOOL_RESULT", ""), out)
    check(not os.path.exists(os.path.join(app, "backend", "tools", "opencode")), "opencode must not be installed")


@test
def t_a3_hash_tamper():
    c = new_case("a3")
    oc, jre = good_zips(c)
    def mut(l):
        h = l["opencode"]["variants"]["x64"]["sha256"]
        l["opencode"]["variants"]["x64"]["sha256"] = ("0" if h[0] != "0" else "1") + h[1:]
    lock = write_lock(c, oc, jre, mutate=mut)
    app = os.path.join(c, "app")
    rc, out = run(lock, app, ["--only", "opencode", "--variant", "x64"])
    check(rc == 30, "exit %s\n%s" % (rc, out))
    check("TOOL opencode FAIL hash" in out, out)
    check(not os.path.exists(os.path.join(app, "backend", "tools", "opencode", "opencode.exe")), "exe must not exist")
    check(not leftovers(app), "leftovers %s" % leftovers(app))
    check(not os.path.exists(os.path.join(app, "runtime", "dl")), "runtime\\dl")


@test
def t_a3_hash_tamper_keeps_old_install():
    c = new_case("a3b")
    oc, jre = good_zips(c, b"v1")
    app = os.path.join(c, "app")
    rc, out = run(write_lock(c, oc, jre), app, ["--only", "opencode", "--variant", "x64"])
    check(rc == 0, out)
    # new version whose hash does not match
    oc2 = os.path.join(c, "oc2.zip")
    make_zip(oc2, [("opencode.exe", b"MZ-fake-opencode-v2")])
    def mut(l):
        l["opencode"]["version"] = "1.20.0"
        l["opencode"]["variants"]["x64"]["sha256"] = "f" * 64
    lock2 = write_lock(c, oc2, jre, mutate=mut)
    rc, out = run(lock2, app, ["--only", "opencode", "--variant", "x64"])
    check(rc == 30 and "FAIL hash" in out, out)
    exe = os.path.join(app, "backend", "tools", "opencode", "opencode.exe")
    check(open(exe, "rb").read() == b"MZ-fake-opencode-v1", "old install must stay untouched")
    check(not leftovers(app), "leftovers")


@test
def t_a4_size_tamper():
    for variant_size, label in ((1, "smaller"), (10 ** 9, "bigger")):
        c = new_case("a4_" + label)
        oc, jre = good_zips(c)
        def mut(l, vs=variant_size):
            l["opencode"]["variants"]["x64"]["size"] = vs
        lock = write_lock(c, oc, jre, mutate=mut)
        app = os.path.join(c, "app")
        rc, out = run(lock, app, ["--only", "opencode", "--variant", "x64"])
        check(rc == 30, "%s: exit %s\n%s" % (label, rc, out))
        check("TOOL opencode FAIL hash" in out, out)
        check(not os.path.exists(os.path.join(app, "backend", "tools", "opencode")), "dest must not exist")
        check(not leftovers(app), "leftovers")


def _slip_case(name, evil_name, extra=()):
    c = new_case(name)
    jre = os.path.join(c, "jre.zip")
    make_zip(jre, [("jdk/bin/java.exe", b"x")])
    oc = os.path.join(c, "oc.zip")
    make_zip(oc, [("opencode.exe", b"MZ")] + list(extra) + [(evil_name, b"EVIL")])
    lock = write_lock(c, oc, jre)
    app = os.path.join(c, "app")
    rc, out = run(lock, app, ["--only", "opencode", "--variant", "x64"])
    return c, app, rc, out


@test
def t_a5_zip_slip_names():
    cases = ["..\\evil.txt", "../evil.txt", "sub/../../evil.txt", "/abs_evil.txt", "\\abs_evil2.txt",
             "C:\\evil_drive.txt", "C:evil_drive2.txt", "ok/.. /x.txt", "ok/.../x.txt", "evil.txt:stream"]
    for i, nm in enumerate(cases):
        c, app, rc, out = _slip_case("a5_%d" % i, nm)
        check(rc == 1, "%r: exit %s\n%s" % (nm, rc, out))
        check("TOOL opencode FAIL zip" in out, "%r: %s" % (nm, out))
        check("Traceback" not in out, out)
        check(not os.path.exists(os.path.join(app, "backend", "tools", "opencode")), "%r: dest must not exist" % nm)
        check(not leftovers(app), "%r: leftovers" % nm)
        # nothing may appear outside the app folder inside this case, nor next to it
        stray = [f for f in tree(c) if not f.startswith(app) and os.path.basename(f) not in ("oc.zip", "jre.zip", "lock.json")]
        check(not stray, "%r: stray files %s" % (nm, stray))
        for outside in (os.path.join(os.path.dirname(c), "evil.txt"), os.path.join(ROOT, "evil.txt")):
            check(not os.path.exists(outside), "escaped to " + outside)
    check(not os.path.exists("C:\\evil_drive.txt") and not os.path.exists("C:\\abs_evil.txt"), "drive root polluted")


@test
def t_a5_symlink_entry_rejected():
    c = new_case("a5_symlink")
    jre = os.path.join(c, "jre.zip")
    make_zip(jre, [("jdk/bin/java.exe", b"x")])
    oc = os.path.join(c, "oc.zip")
    with zipfile.ZipFile(oc, "w") as z:
        z.writestr("opencode.exe", b"MZ")
        zi = zipfile.ZipInfo("link")
        zi.external_attr = (0o120777 << 16)
        z.writestr(zi, "C:/Windows")
    app = os.path.join(c, "app")
    rc, out = run(write_lock(c, oc, jre), app, ["--only", "opencode", "--variant", "x64"])
    check(rc == 1 and "FAIL zip" in out, out)
    check(not os.path.exists(os.path.join(app, "backend", "tools", "opencode")), "dest")


@test
def t_zip_bomb_cap():
    c = new_case("bomb")
    jre = os.path.join(c, "jre.zip")
    make_zip(jre, [("jdk/bin/java.exe", b"x")])
    oc = os.path.join(c, "oc.zip")
    make_zip(oc, [("opencode.exe", b"MZ"), ("big.bin", b"\0" * 200000)])
    app = os.path.join(c, "app")
    rc, out = run(write_lock(c, oc, jre), app, ["--only", "opencode", "--variant", "x64"], env_extra={"HOEHWA_TOOLS_MAXUNZIP": "50000"})
    check(rc == 1 and "FAIL zip" in out, out)
    check(not os.path.exists(os.path.join(app, "backend", "tools", "opencode")), "dest")
    check(not leftovers(app), "leftovers")


@test
def t_missing_exe_in_zip():
    c = new_case("noexe")
    jre = os.path.join(c, "jre.zip")
    make_zip(jre, [("jdk/bin/java.exe", b"x")])
    oc = os.path.join(c, "oc.zip")
    make_zip(oc, [("readme.txt", b"hello")])
    app = os.path.join(c, "app")
    rc, out = run(write_lock(c, oc, jre), app, ["--only", "opencode", "--variant", "x64"])
    check(rc == 1 and "TOOL opencode FAIL zip" in out, out)
    check(not os.path.exists(os.path.join(app, "backend", "tools", "opencode")), "dest")
    check(not leftovers(app), "leftovers")
    # JRE without bin\java.exe
    c2 = new_case("nojava")
    oc2, _ = good_zips(c2)
    jre2 = os.path.join(c2, "jre.zip")
    make_zip(jre2, [("jdk/readme", b"x")])
    rc, out = run(write_lock(c2, oc2, jre2), os.path.join(c2, "app"), ["--only", "jre"])
    check(rc == 1 and "TOOL jre FAIL zip" in out, out)


@test
def t_not_a_zip_with_right_hash():
    c = new_case("notzip")
    oc = os.path.join(c, "oc.zip")
    open(oc, "wb").write(b"this is not a zip file at all")
    jre = os.path.join(c, "jre.zip")
    make_zip(jre, [("jdk/bin/java.exe", b"x")])
    app = os.path.join(c, "app")
    rc, out = run(write_lock(c, oc, jre), app, ["--only", "opencode", "--variant", "x64"])
    check(rc == 1 and "FAIL zip" in out and "Traceback" not in out, out)
    check(not leftovers(app), "leftovers")


@test
def t_a6_broken_json():
    c = new_case("a6")
    for i, content in enumerate([b"{ this is : not json", b"", b"[]", b'{"schema": 1}', b'{"schema": 2, "opencode": {}, "jre": {}}', b"\xff\xfe\x00bad"]):
        lock = os.path.join(c, "bad%d.json" % i)
        open(lock, "wb").write(content)
        rc, out = run(lock, os.path.join(c, "app"))
        check(rc == 1, "case %d exit %s\n%s" % (i, rc, out))
        check("Traceback" not in out, out)
        check("TOOL_RESULT FAIL" in out, out)
        lines = [l for l in out.splitlines() if l.startswith("TOOL ") and "FAIL" in l]
        check(len(lines) == 1 and any("\uac00" <= ch <= "\ud7a3" for ch in lines[0]), "Korean one-line message: " + out)
    rc, out = run(os.path.join(c, "does_not_exist.json"), os.path.join(c, "app"))
    check(rc == 1 and "Traceback" not in out and "TOOL_RESULT FAIL" in out, out)
    check(not os.path.exists(os.path.join(c, "app")), "app folder must not be created for a bad lock")


@test
def t_lock_validation():
    c = new_case("lockval")
    oc, jre = good_zips(c)
    muts = {
        "dest_escape": lambda l: l["opencode"].__setitem__("dest", "../../evil"),
        "dest_abs": lambda l: l["jre"].__setitem__("dest", "C:/evil"),
        "bad_sha": lambda l: l["jre"].__setitem__("sha256", "xyz"),
        "bad_size": lambda l: l["jre"].__setitem__("size", "big"),
        "exe_path": lambda l: l["opencode"].__setitem__("exe", "..\\x.exe"),
    }
    for name, m in muts.items():
        lock = write_lock(c, oc, jre, mutate=m)
        rc, out = run(lock, os.path.join(c, "app_" + name))
        check(rc == 1 and "Traceback" not in out and "TOOL_RESULT FAIL" in out, "%s: %s %s" % (name, rc, out))
        check(not os.path.exists(os.path.join(c, "app_" + name, "backend")), name + ": must not install")
    check(not os.path.exists(os.path.join(c, "evil")) and not os.path.exists("C:\\evil"), "escaped")


@test
def t_a7_http_rejected():
    c = new_case("a7")
    oc, jre = good_zips(c)
    for scheme_url in ("http://127.0.0.1:1/opencode.zip", "ftp://example.com/x.zip", "file:///C:/Windows/notepad.exe"):
        def mut(l, u=scheme_url):
            l["opencode"]["variants"]["x64"]["url"] = u
        lock = write_lock(c, oc, jre, mutate=mut)
        rc, out = run(lock, os.path.join(c, "app"), ["--only", "opencode", "--variant", "x64"], test_mode=False)
        check(rc == 1, "%s: exit %s\n%s" % (scheme_url, rc, out))
        check("https" in out and "FAIL" in out, out)
    # TEST_MODE allows file:/// but still never http://
    def mut2(l):
        l["opencode"]["variants"]["x64"]["url"] = "http://127.0.0.1:1/x.zip"
    rc, out = run(write_lock(c, oc, jre, mutate=mut2), os.path.join(c, "app2"), ["--only", "opencode", "--variant", "x64"])
    check(rc == 1 and "https" in out, out)
    # good file:/// url is refused without HOEHWA_TEST_MODE (a shipped install ignores the hook)
    rc, out = run(write_lock(c, oc, jre), os.path.join(c, "app3"), ["--only", "opencode", "--variant", "x64"], test_mode=False)
    check(rc == 1 and "https" in out, out)
    check(not os.path.exists(os.path.join(c, "app3", "backend")), "nothing installed")


@test
def t_a8_skip_without_network():
    c = new_case("a8")
    oc, jre = good_zips(c)
    lock = write_lock(c, oc, jre)
    app = os.path.join(c, "app")
    rc, out = run(lock, app)
    check(rc == 0 and "TOOL opencode OK" in out and "TOOL jre OK" in out, out)
    os.remove(oc)
    os.remove(jre)                         # source gone: a SKIP must not try to download
    rc, out = run(lock, app)
    check(rc == 0, out)
    check("TOOL opencode SKIP" in out and "TOOL jre SKIP" in out, out)
    check(not leftovers(app), "leftovers")


@test
def t_new_version_replaces_old():
    c = new_case("upgrade")
    oc, jre = good_zips(c, b"v1")
    app = os.path.join(c, "app")
    check(run(write_lock(c, oc, jre, oc_ver="1.19.0"), app)[0] == 0, "first")
    # older JRE folder that this installer put there is replaced; user's own folder is kept
    os.makedirs(os.path.join(app, "backend", "tools", "languagetool"))
    oc2 = os.path.join(c, "oc2.zip")
    make_zip(oc2, [("opencode.exe", b"MZ-fake-opencode-v2")])
    jre2 = os.path.join(c, "jre2.zip")
    make_zip(jre2, [("jdk-21.0.14+1-jre/bin/java.exe", b"MZ-java2")])
    def mut(l):
        l["jre"]["version"] = "21.0.14+1"
    rc, out = run(write_lock(c, oc2, jre2, oc_ver="1.20.0", mutate=mut), app)
    check(rc == 0 and "TOOL opencode OK 1.20.0" in out and "TOOL jre OK 21.0.14+1" in out, out)
    check(open(os.path.join(app, "backend", "tools", "opencode", "opencode.exe"), "rb").read() == b"MZ-fake-opencode-v2", "exe not replaced")
    check(not os.path.exists(os.path.join(app, "backend", "tools", "jdk-21.0.13+9-jre")), "old jre folder should be gone")
    check(os.path.isfile(os.path.join(app, "backend", "tools", "jdk-21.0.14+1-jre", "bin", "java.exe")), "new jre")
    check(os.path.isdir(os.path.join(app, "backend", "tools", "languagetool")), "foreign folder must stay")
    check(not leftovers(app), "leftovers")


@test
def t_exe_in_subfolder_is_found():
    c = new_case("subdir")
    jre = os.path.join(c, "jre.zip")
    make_zip(jre, [("jdk/bin/java.exe", b"x")])
    oc = os.path.join(c, "oc.zip")
    make_zip(oc, [("opencode-windows-x64/opencode.exe", b"MZ-sub"), ("opencode-windows-x64/LICENSE", b"l")])
    app = os.path.join(c, "app")
    rc, out = run(write_lock(c, oc, jre), app, ["--only", "opencode", "--variant", "x64"])
    check(rc == 0, out)
    check(os.path.isfile(os.path.join(app, "backend", "tools", "opencode", "opencode.exe")), "exe at the final place")
    check(os.path.isfile(os.path.join(app, "backend", "tools", "opencode", "LICENSE")), "siblings moved too")
    check(not leftovers(app), "leftovers")


@test
def t_variant_auto_follows_avx2():
    c = new_case("variant")
    oc = os.path.join(c, "oc_x64.zip")
    base = os.path.join(c, "oc_base.zip")
    make_zip(oc, [("opencode.exe", b"MZ-X64")])
    make_zip(base, [("opencode.exe", b"MZ-BASELINE")])
    jre = os.path.join(c, "jre.zip")
    make_zip(jre, [("jdk/bin/java.exe", b"x")])
    lock = write_lock(c, oc, jre, base_zip=base)
    for avx2, want in (("1", b"MZ-X64"), ("0", b"MZ-BASELINE")):
        app = os.path.join(c, "app_" + avx2)
        rc, out = run(lock, app, ["--only", "opencode"], env_extra={"HOEHWA_TOOLS_AVX2": avx2})
        check(rc == 0, out)
        check(open(os.path.join(app, "backend", "tools", "opencode", "opencode.exe"), "rb").read() == want, "variant for avx2=" + avx2)
    app = os.path.join(c, "app_forced")
    rc, out = run(lock, app, ["--only", "opencode", "--variant", "x64-baseline"], env_extra={"HOEHWA_TOOLS_AVX2": "1"})
    check(open(os.path.join(app, "backend", "tools", "opencode", "opencode.exe"), "rb").read() == b"MZ-BASELINE", "forced variant")
    rc, out = run(lock, os.path.join(c, "app_bad"), ["--variant", "arm64"])
    check(rc == 1 and "TOOL_RESULT FAIL" in out and "Traceback" not in out, out)


@test
def t_progress_file_monotonic_and_valid():
    c = new_case("progress")
    oc, jre = good_zips(c)
    lock = write_lock(c, oc, jre)
    # a tiny wrapper records every progress value the tool writes
    seen = []
    sys.path.insert(0, os.path.join(HERE, "installer"))
    os.environ["HOEHWA_TEST_MODE"] = "1"
    import importlib
    it = importlib.import_module("install_tools")
    pf = os.path.join(c, "p.json")
    pr = it.Progress(pf)
    for v in (5, 20, 10, 50, 50, 99, 100):
        pr.set(v)
        j = json.load(open(pf, encoding="utf-8"))
        seen.append(j["pct"])
    check(seen == [5, 20, 20, 50, 50, 99, 100], "monotonic: %s" % seen)
    check(not os.path.exists(pf + ".tmp"), "tmp file left")
    rc, out = run(lock, os.path.join(c, "app"), ["--progress-file", os.path.join(c, "q.json")])
    j = json.load(open(os.path.join(c, "q.json"), encoding="utf-8"))
    check(rc == 0 and j["pct"] == 100, str(j))


@test
def t_https_only_redirect():
    sys.path.insert(0, os.path.join(HERE, "installer"))
    import importlib
    it = importlib.import_module("install_tools")
    h = it._HttpsOnlyRedirect()
    try:
        h.redirect_request(None, None, 302, "Found", {}, "http://evil.example/x.zip")
        raise AssertionError("http redirect was accepted")
    except urllib.error.URLError:
        pass
    try:
        h.redirect_request(None, None, 302, "Found", {}, "ftp://evil.example/x.zip")
        raise AssertionError("ftp redirect was accepted")
    except urllib.error.URLError:
        pass


@test
def t_input_closed_and_no_secret_paths():
    c = new_case("stdin")
    oc, jre = good_zips(c)
    app = os.path.join(c, "app")
    rc, out = run(write_lock(c, oc, jre), app, stdin_null=True)
    check(rc == 0, out)
    src = open(TOOL, encoding="utf-8").read()
    for bad in ("APPDATA", ".local", "auth.json", "node_modules", "input("):
        check(bad not in src, "forbidden text in install_tools.py: " + bad)


@test
def t_network_failure_is_exit_20():
    c = new_case("net")
    oc, jre = good_zips(c)
    def mut(l):
        l["opencode"]["variants"]["x64"]["url"] = file_url(os.path.join(c, "nope.zip"))
    app = os.path.join(c, "app")
    rc, out = run(write_lock(c, oc, jre, mutate=mut), app, ["--only", "opencode", "--variant", "x64"])
    check(rc == 20 and "TOOL opencode FAIL net" in out, "exit %s\n%s" % (rc, out))
    check(not leftovers(app), "leftovers")


@test
def t_mixed_failures_exit_code_priority():
    c = new_case("mixed")
    oc, jre = good_zips(c)
    def mut(l):
        l["opencode"]["variants"]["x64"]["url"] = file_url(os.path.join(c, "nope.zip"))     # net (20)
        l["jre"]["sha256"] = "a" * 64                                                        # hash (30)
    app = os.path.join(c, "app")
    rc, out = run(write_lock(c, oc, jre, mutate=mut), app, ["--variant", "x64"])
    check(rc == 30 and "FAIL net" in out and "FAIL hash" in out and "TOOL_RESULT FAIL" in out, "exit %s\n%s" % (rc, out))


# ------------------------------------------------------------------------------------------------ end
shutil.rmtree(ROOT, ignore_errors=True)
passed = sum(1 for _, ok, _ in results if ok)
total = len(results)
for n, ok, why in results:
    if not ok:
        print("FAILED: %s -- %s" % (n, why))
print("INSTALL_TOOLS_TEST %s %d/%d" % ("PASS" if passed == total else "FAIL", passed, total))
sys.exit(0 if passed == total else 1)
