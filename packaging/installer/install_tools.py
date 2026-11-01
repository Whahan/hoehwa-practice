# -*- coding: utf-8 -*-
"""Runtime tool installer: downloads OpenCode (opencode.exe) and a portable Java runtime (JRE) into the app folder.

    python -X utf8 install_tools.py <tools.lock.json> <app_root> [--only opencode|jre|all]
            [--variant auto|x64|x64-baseline] [--progress-file F]

Output lines (stdout, UTF-8):
    TOOL <name> OK <version> <install path>
    TOOL <name> SKIP <version> (이미 같은 버전)
    TOOL <name> FAIL <hash|net|zip|other> <Korean reason>
    TOOL_RESULT OK | TOOL_RESULT FAIL
Exit code: 0 OK / 20 internet / 30 hash or size mismatch / 1 anything else.

Rules this script keeps (the downloaded file is untrusted data until it is verified):
  * only https:// is accepted (file:/// additionally when HOEHWA_TEST_MODE=1); redirects to anything but https are refused
  * the archive is NOT opened before its size and SHA256 match the lock file
  * every archive entry name is checked first (absolute path, "..", drive letter, ":" ...) -- nothing is written if one is bad
  * extraction goes to a ".new" folder next to the destination and is moved into place only after the exe was found
  * downloads (.part), the ".new" folder and empty folders created by this run are removed on success AND on failure
Standard library only. It never reads or writes OpenCode's own login/auth files or any npm folder.
"""
import argparse
import hashlib
import json
import os
import re
import shutil
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import zipfile

TEST_MODE = os.environ.get("HOEHWA_TEST_MODE") == "1"

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

EXIT_OK, EXIT_OTHER, EXIT_NET, EXIT_HASH = 0, 1, 20, 30
TOOL_NAMES = ("opencode", "jre")
MAX_UNZIP_BYTES = 1_500_000_000          # zip-bomb guard (opencode ~180MB, jre ~100MB unpacked)
if TEST_MODE and os.environ.get("HOEHWA_TOOLS_MAXUNZIP", "").isdigit():
    MAX_UNZIP_BYTES = int(os.environ["HOEHWA_TOOLS_MAXUNZIP"])
CHUNK = 1024 * 1024
RETRIES = 3
HEX64 = re.compile(r"^[0-9a-fA-F]{64}$")


class ToolError(Exception):
    """kind: hash | net | zip | other"""

    def __init__(self, kind, msg):
        Exception.__init__(self, msg)
        self.kind = kind
        self.msg = msg


def one_line(s):
    return re.sub(r"\s+", " ", str(s)).strip()[:200]


# ------------------------------------------------------------------------------------------- progress
class Progress:
    def __init__(self, path):
        self.path = path
        self.last = -1

    def set(self, pct, tool=""):
        if not self.path:
            return
        pct = max(0, min(100, int(pct)))
        if pct < self.last:        # never goes backwards
            pct = self.last
        if pct == self.last and pct not in (0, 100):
            return
        self.last = pct
        try:
            tmp = self.path + ".tmp"
            with open(tmp, "w", encoding="utf-8", newline="") as f:
                json.dump({"pct": pct, "tool": tool, "state": "running"}, f)
            os.replace(tmp, self.path)
        except OSError:
            pass


# ------------------------------------------------------------------------------------------- dirs
class DirTracker:
    """Remembers directories this run created so empty ones can be removed at the end."""

    def __init__(self):
        self.made = []

    def makedirs(self, path):
        todo = []
        p = os.path.abspath(path)
        while p and not os.path.isdir(p):
            todo.append(p)
            parent = os.path.dirname(p)
            if parent == p:
                break
            p = parent
        os.makedirs(path, exist_ok=True)
        self.made.extend(reversed(todo))

    def cleanup(self):
        for d in reversed(self.made):
            try:
                os.rmdir(d)        # only succeeds when empty
            except OSError:
                pass


def rmtree_quiet(path):
    if os.path.isdir(path) and not os.path.islink(path):
        shutil.rmtree(path, ignore_errors=True)
    elif os.path.lexists(path):
        try:
            os.remove(path)
        except OSError:
            pass


# ------------------------------------------------------------------------------------------- lock file
def _need(cond, msg):
    if not cond:
        raise ToolError("other", msg)


def _check_entry(name, e, rel_dest=True):
    _need(isinstance(e, dict), "%s 항목이 올바르지 않아요." % name)
    _need(isinstance(e.get("url"), str) and e["url"], "%s의 주소(url)가 없어요." % name)
    _need(isinstance(e.get("sha256"), str) and HEX64.match(e["sha256"]), "%s의 sha256 값이 올바르지 않아요." % name)
    _need(isinstance(e.get("size"), int) and not isinstance(e["size"], bool) and e["size"] > 0, "%s의 size 값이 올바르지 않아요." % name)


def _safe_rel(path, what):
    _need(isinstance(path, str) and path, "%s 경로가 없어요." % what)
    norm = path.replace("\\", "/")
    parts = [p for p in norm.split("/") if p]
    _need(not norm.startswith("/") and not re.match(r"^[A-Za-z]:", norm) and ".." not in parts and parts,
          "%s 경로가 앱 폴더 밖을 가리켜요." % what)
    return os.path.join(*parts)


def load_lock(path):
    try:
        with open(path, "r", encoding="utf-8-sig") as f:
            d = json.load(f)
    except FileNotFoundError:
        raise ToolError("other", "잠금 파일을 찾을 수 없어요: %s" % os.path.basename(path))
    except (OSError, ValueError, UnicodeDecodeError) as e:
        raise ToolError("other", "잠금 파일(tools.lock.json)을 읽지 못했어요: %s" % type(e).__name__)
    _need(isinstance(d, dict) and d.get("schema") == 1, "잠금 파일 형식(schema)이 맞지 않아요.")
    oc = d.get("opencode")
    _need(isinstance(oc, dict), "잠금 파일에 opencode 항목이 없어요.")
    _need(isinstance(oc.get("version"), str) and oc["version"], "opencode 버전이 없어요.")
    _safe_rel(oc.get("dest"), "opencode dest")
    exe = oc.get("exe")
    _need(isinstance(exe, str) and exe and not re.search(r"[\\/:]", exe), "opencode exe 이름이 올바르지 않아요.")
    _need(isinstance(oc.get("variants"), dict) and oc["variants"], "opencode variants가 없어요.")
    for vn, ve in oc["variants"].items():
        _check_entry("opencode/%s" % vn, ve)
    jre = d.get("jre")
    _need(isinstance(jre, dict), "잠금 파일에 jre 항목이 없어요.")
    _need(isinstance(jre.get("version"), str) and jre["version"], "jre 버전이 없어요.")
    _safe_rel(jre.get("dest"), "jre dest")
    _check_entry("jre", jre)
    return d


# ------------------------------------------------------------------------------------------- download
class _HttpsOnlyRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        if urllib.parse.urlparse(newurl).scheme.lower() != "https":
            raise urllib.error.URLError("https가 아닌 주소로 넘기려 해서 막았어요")
        return urllib.request.HTTPRedirectHandler.redirect_request(self, req, fp, code, msg, headers, newurl)


def check_url(url):
    scheme = urllib.parse.urlparse(url).scheme.lower()
    if scheme == "https":
        return
    if scheme == "file" and TEST_MODE:
        return
    raise ToolError("other", "https 주소만 받을 수 있어요(받으려던 주소가 https가 아니에요).")


def _open_url(url):
    if urllib.parse.urlparse(url).scheme.lower() == "file":
        return urllib.request.urlopen(url, timeout=60)
    opener = urllib.request.build_opener(_HttpsOnlyRedirect)
    req = urllib.request.Request(url, headers={"User-Agent": "hoehwa-practice-installer"})
    return opener.open(req, timeout=60)


def download_verified(url, size, sha256, part_path, progress_cb):
    """Download to part_path and verify. Returns on success; raises ToolError(net|hash|other)."""
    check_url(url)
    last_err = "알 수 없는 오류"
    for attempt in range(1, RETRIES + 1):
        h = hashlib.sha256()
        got = 0
        try:
            with _open_url(url) as resp:
                clen = resp.headers.get("Content-Length") if hasattr(resp, "headers") else None
                clen = int(clen) if clen and clen.isdigit() else None
                with open(part_path, "wb") as out:
                    while True:
                        b = resp.read(CHUNK)
                        if not b:
                            break
                        got += len(b)
                        if got > size:              # more than the lock says: stop right away
                            raise ToolError("hash", "받은 파일 크기가 잠금 값과 달라요(더 커요). 파일이 바뀐 것 같아요.")
                        h.update(b)
                        out.write(b)
                        progress_cb(got, size)
            if clen is not None and got != clen:
                raise urllib.error.URLError("받는 도중 끊겼어요(%d/%d)" % (got, clen))
        except ToolError:
            raise
        except (urllib.error.URLError, OSError, ValueError, TimeoutError) as e:
            last_err = type(e).__name__ + (": " + one_line(getattr(e, "reason", "")) if getattr(e, "reason", "") else "")
            if isinstance(e, OSError) and not isinstance(e, urllib.error.URLError) and getattr(e, "errno", None) in (28, 13, 5):
                raise ToolError("other", "파일을 쓰지 못했어요(디스크 공간이나 권한을 확인해 주세요).")
            if attempt < RETRIES:
                time.sleep(0 if TEST_MODE else 2 * attempt)
            continue
        # fully received
        if got != size:
            raise ToolError("hash", "받은 파일 크기가 잠금 값과 달라요(%d바이트, 기대 %d)." % (got, size))
        if h.hexdigest().lower() != sha256.lower():
            raise ToolError("hash", "받은 파일의 SHA256이 잠금 값과 달라요. 파일이 바뀐 것 같아서 풀지 않았어요.")
        return
    raise ToolError("net", "인터넷에서 받지 못했어요(%s). 연결을 확인하고 다시 실행해 주세요." % last_err)


# ------------------------------------------------------------------------------------------- unzip
def check_member_name(name):
    """Raise ToolError('zip') unless the entry name is a plain relative path inside the archive root."""
    bad = ToolError("zip", "압축 파일 안에 위험한 경로가 있어서 풀지 않았어요(%s)." % one_line(name)[:80])
    if not name or "\x00" in name:
        raise bad
    norm = name.replace("\\", "/")
    if norm.startswith("/") or re.match(r"^[A-Za-z]:", norm) or ":" in norm:
        raise bad
    for comp in norm.split("/"):
        if comp in ("", "."):
            continue
        if comp.strip(" .") == "" or comp != comp.rstrip(" ."):      # "..", ".. ", "..." (Windows trims trailing dots/spaces)
            raise bad
    return norm


def safe_extract(zip_path, stage):
    try:
        zf = zipfile.ZipFile(zip_path)
    except (zipfile.BadZipFile, OSError, NotImplementedError) as e:
        raise ToolError("zip", "받은 압축 파일을 열 수 없어요(%s)." % type(e).__name__)
    with zf:
        infos = zf.infolist()
        total = 0
        names = []
        for zi in infos:                                  # 1) check everything BEFORE writing anything
            names.append(check_member_name(zi.filename))
            if (zi.external_attr >> 16) & 0o170000 == 0o120000:
                raise ToolError("zip", "압축 파일 안에 바로가기(symlink) 항목이 있어서 풀지 않았어요.")
            total += zi.file_size
        if total > MAX_UNZIP_BYTES:
            raise ToolError("zip", "압축을 풀면 너무 커져서 풀지 않았어요.")
        os.makedirs(stage, exist_ok=True)
        base = os.path.realpath(stage)
        written = 0
        for zi, norm in zip(infos, names):                # 2) extract; also re-check the final path
            target = os.path.realpath(os.path.join(base, *[c for c in norm.split("/") if c not in ("", ".")]))
            if target != base and not target.startswith(base + os.sep):
                raise ToolError("zip", "압축 파일 안에 위험한 경로가 있어서 풀지 않았어요.")
            if zi.is_dir() or norm.endswith("/"):
                os.makedirs(target, exist_ok=True)
                continue
            os.makedirs(os.path.dirname(target), exist_ok=True)
            with zf.open(zi) as src, open(target, "wb") as dst:
                while True:
                    b = src.read(CHUNK)
                    if not b:
                        break
                    written += len(b)
                    if written > MAX_UNZIP_BYTES:
                        raise ToolError("zip", "압축을 풀면 너무 커져서 풀지 않았어요.")
                    dst.write(b)


def find_file(root, rel_parts, max_depth=3):
    """Shallowest directory under root (incl. root) that contains the relative path rel_parts. Returns dir or None."""
    level = [root]
    for _ in range(max_depth + 1):
        nxt = []
        for d in level:
            if os.path.isfile(os.path.join(d, *rel_parts)):
                return d
            try:
                for e in sorted(os.listdir(d)):
                    p = os.path.join(d, e)
                    if os.path.isdir(p) and not os.path.islink(p):
                        nxt.append(p)
            except OSError:
                pass
        level = nxt
    return None


# ------------------------------------------------------------------------------------------- install helpers
def read_tool_json(d):
    try:
        with open(os.path.join(d, "tool.json"), "r", encoding="utf-8") as f:
            j = json.load(f)
        return j if isinstance(j, dict) else None
    except (OSError, ValueError):
        return None


def swap_in(new_dir, final_dir):
    """Move new_dir to final_dir; an existing final_dir is set aside first and restored if the move fails."""
    old = None
    if os.path.lexists(final_dir):
        old = final_dir + ".old"
        rmtree_quiet(old)
        try:
            os.rename(final_dir, old)
        except OSError:
            raise ToolError("other", "기존 폴더를 치우지 못했어요. 실행 중인 프로그램을 끄고 다시 해 주세요.")
    try:
        os.rename(new_dir, final_dir)
    except OSError:
        if old:
            try:
                os.rename(old, final_dir)
            except OSError:
                pass
        raise ToolError("other", "새 폴더를 제자리로 옮기지 못했어요.")
    if old:
        rmtree_quiet(old)


def has_avx2():
    if TEST_MODE and os.environ.get("HOEHWA_TOOLS_AVX2") in ("0", "1"):
        return os.environ["HOEHWA_TOOLS_AVX2"] == "1"
    try:
        import ctypes
        return bool(ctypes.windll.kernel32.IsProcessorFeaturePresent(40))     # PF_AVX2_INSTRUCTIONS_AVAILABLE
    except Exception:
        return None


def install_one(name, version, entry, dest_rel, kind, exe_rel, app_root, dirs, prog, pct_lo, pct_hi):
    """Common flow for one archive. kind='opencode' (dest is the final dir) or 'jre' (dest holds the top folder)."""
    dest = os.path.normpath(os.path.join(app_root, _safe_rel(dest_rel, "dest")))
    sha = entry["sha256"].lower()
    # --- already installed? (same version + same archive hash)
    if kind == "opencode":
        j = read_tool_json(dest)
        if j and j.get("version") == version and str(j.get("sha256", "")).lower() == sha and os.path.isfile(os.path.join(dest, *exe_rel)):
            return "SKIP", dest
    else:
        if os.path.isdir(dest):
            for e in sorted(os.listdir(dest)):
                d = os.path.join(dest, e)
                j = read_tool_json(d) if os.path.isdir(d) else None
                if j and j.get("name") == "jre" and j.get("version") == version and str(j.get("sha256", "")).lower() == sha \
                        and os.path.isfile(os.path.join(d, *exe_rel)):
                    return "SKIP", d
    dl_dir = os.path.join(app_root, "runtime", "dl")
    part = os.path.join(dl_dir, name + ".part")
    stage = (dest + ".new") if kind == "opencode" else os.path.join(dest, "jre.new")
    try:
        dirs.makedirs(dl_dir)
        dl_span = (pct_hi - pct_lo) * 0.85
        prog.set(pct_lo, name)
        download_verified(entry["url"], entry["size"], sha, part,
                          lambda got, size: prog.set(pct_lo + dl_span * got / max(1, size), name))
        rmtree_quiet(stage)
        dirs.makedirs(os.path.dirname(stage))
        safe_extract(part, stage)
        try:
            os.remove(part)                         # zip is no longer needed
        except OSError:
            pass
        prog.set(pct_lo + (pct_hi - pct_lo) * 0.92, name)
        root = find_file(stage, exe_rel)
        if root is None:
            raise ToolError("zip", "압축 파일 안에서 %s을(를) 찾지 못했어요." % "\\".join(exe_rel))
        meta = {"name": name, "version": version, "sha256": sha}
        if kind == "opencode":
            content = root
            if content != stage:                    # exe is in a subfolder: that folder becomes the install folder
                tmp2 = stage + "2"
                rmtree_quiet(tmp2)
                os.rename(content, tmp2)
                rmtree_quiet(stage)
                os.rename(tmp2, stage)
                content = stage
            with open(os.path.join(content, "tool.json"), "w", encoding="utf-8") as f:
                json.dump(meta, f)
            swap_in(content, dest)
            final = dest
        else:
            if root == stage:                       # java is directly under stage\bin
                top_name = "jre-" + re.sub(r"[^0-9A-Za-z._-]", "_", version)
            else:
                top_name = os.path.basename(root)
            final = os.path.join(dest, top_name)
            with open(os.path.join(root, "tool.json"), "w", encoding="utf-8") as f:
                json.dump(meta, f)
            # older JRE folders that this installer put there (tool.json name=jre) are replaced
            if os.path.isdir(dest):
                for e in sorted(os.listdir(dest)):
                    d = os.path.join(dest, e)
                    j = read_tool_json(d) if os.path.isdir(d) and d != stage else None
                    if j and j.get("name") == "jre" and d != final:
                        rmtree_quiet(d)
            swap_in(root, final)
        prog.set(pct_hi, name)
        return "OK", final
    finally:
        try:
            if os.path.exists(part):
                os.remove(part)
        except OSError:
            pass
        rmtree_quiet(stage)
        rmtree_quiet(stage + "2")
        try:
            os.rmdir(dl_dir)
        except OSError:
            pass


# ------------------------------------------------------------------------------------------- main
class _Parser(argparse.ArgumentParser):
    def error(self, message):
        print("TOOL_RESULT FAIL")
        print("명령줄 인자가 올바르지 않아요: %s" % one_line(message))
        sys.exit(EXIT_OTHER)


def run(argv):
    ap = _Parser(prog="install_tools.py", add_help=False)
    ap.add_argument("lock")
    ap.add_argument("app_root")
    ap.add_argument("--only", default="all", choices=("opencode", "jre", "all"))
    ap.add_argument("--variant", default="auto", choices=("auto", "x64", "x64-baseline"))
    ap.add_argument("--progress-file", default="")
    a = ap.parse_args(argv)

    try:
        lock = load_lock(a.lock)
    except ToolError as e:
        print("TOOL lock FAIL other %s" % e.msg)
        print("TOOL_RESULT FAIL")
        return EXIT_OTHER

    wanted = list(TOOL_NAMES) if a.only == "all" else [a.only]
    app_root = os.path.abspath(a.app_root)
    prog = Progress(a.progress_file)
    dirs = DirTracker()
    try:
        dirs.makedirs(app_root)
    except OSError:
        print("TOOL lock FAIL other 앱 폴더를 만들 수 없어요.")
        print("TOOL_RESULT FAIL")
        return EXIT_OTHER
    sizes = {"opencode": 0, "jre": 0}
    sizes["jre"] = lock["jre"]["size"]
    code = EXIT_OK
    prio = {EXIT_OK: 0, EXIT_OTHER: 1, EXIT_NET: 2, EXIT_HASH: 3}
    kind_code = {"hash": EXIT_HASH, "net": EXIT_NET, "zip": EXIT_OTHER, "other": EXIT_OTHER}
    # choose the opencode variant
    oc = lock["opencode"]
    variant = a.variant
    if variant == "auto":
        avx2 = has_avx2()
        variant = "x64" if avx2 else "x64-baseline"      # unknown (None) -> baseline, which runs everywhere
    if "opencode" in wanted and variant not in oc["variants"]:
        print("TOOL opencode FAIL other 잠금 파일에 %s 항목이 없어요." % variant)
        print("TOOL_RESULT FAIL")
        dirs.cleanup()
        return EXIT_OTHER
    if "opencode" in wanted:
        sizes["opencode"] = oc["variants"][variant]["size"]
    total = sum(sizes[n] for n in wanted) or 1
    done = 0
    for name in wanted:
        lo = 100.0 * done / total
        hi = 100.0 * (done + sizes[name]) / total
        done += sizes[name]
        try:
            if name == "opencode":
                status, path = install_one("opencode", oc["version"], oc["variants"][variant], oc["dest"], "opencode",
                                           (oc["exe"],), app_root, dirs, prog, lo, hi)
                ver = oc["version"]
            else:
                jre = lock["jre"]
                status, path = install_one("jre", jre["version"], jre, jre["dest"], "jre", ("bin", "java.exe"),
                                           app_root, dirs, prog, lo, hi)
                ver = jre["version"]
            if status == "SKIP":
                print("TOOL %s SKIP %s (이미 같은 버전)" % (name, ver))
            else:
                print("TOOL %s OK %s %s" % (name, ver, path))
            prog.set(hi, name)
        except ToolError as e:
            print("TOOL %s FAIL %s %s" % (name, e.kind, e.msg))
            c = kind_code.get(e.kind, EXIT_OTHER)
            if prio[c] > prio[code]:
                code = c
        except Exception as e:             # never show a stack trace to the user
            print("TOOL %s FAIL other 예상하지 못한 오류예요(%s)." % (name, type(e).__name__))
            if prio[EXIT_OTHER] > prio[code]:
                code = EXIT_OTHER
    dirs.cleanup()
    print("TOOL_RESULT OK" if code == EXIT_OK else "TOOL_RESULT FAIL")
    if code == EXIT_OK:
        prog.set(100, "")
    return code


if __name__ == "__main__":
    try:
        sys.exit(run(sys.argv[1:]))
    except SystemExit:
        raise
    except Exception as e:
        print("TOOL_RESULT FAIL")
        print("예상하지 못한 오류예요(%s)." % type(e).__name__)
        sys.exit(EXIT_OTHER)
