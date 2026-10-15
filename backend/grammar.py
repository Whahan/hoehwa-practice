# -*- coding: utf-8 -*-
"""Offline grammar correction with a local LanguageTool server (no AI model needed).

LanguageTool (https://languagetool.org, LGPL) runs as a Java child process on a free 127.0.0.1 port:
    java -cp languagetool-server.jar org.languagetool.server.HTTPServer --port <p> --allow-origin
It is started on first use (or by warmup), tied to this process with a Windows job object (so it dies even if
the backend is killed hard), and stopped by PID at exit. Never by image name.

Files:  backend/tools/languagetool/<LanguageTool-x.y>/languagetool-server.jar  (+ lt.json, written by the installer)
Java:   17+; backend/tools/jre*, JAVA_HOME, PATH, C:\\Program Files\\{Java,Eclipse Adoptium,Microsoft,Zulu}\\*

correct(lang, text) -> {"fix", "fix_ko", "changes": [...]} or None (nothing to fix / not trustworthy / LanguageTool unavailable)
"""
import atexit
import glob
import json
import os
import re
import shutil
import socket
import subprocess
import threading
import time

import requests

BASE = os.path.dirname(os.path.abspath(__file__))
TOOLS = os.path.join(BASE, "tools")
LT_DIR = os.path.join(TOOLS, "languagetool")
LOG_DIR = os.path.join(BASE, "logs")
NO_WINDOW = 0x08000000
LANG_CODE = {"en": "en-US", "ja": "ja-JP"}

_log = None


def init(log=None):
    global _log
    _log = log


def _info(msg, *a):
    if _log:
        _log.info(msg, *a)


def _warn(msg, *a):
    if _log:
        _log.warning(msg, *a)


# ---------------------------------------------------------------------------------------------- files
def find_jar():
    """Path of languagetool-server.jar, preferring the version recorded in tools/languagetool/lt.json."""
    try:
        with open(os.path.join(LT_DIR, "lt.json"), encoding="utf-8") as f:
            d = json.load(f).get("dir")
        if d:
            p = os.path.join(LT_DIR, d, "languagetool-server.jar")
            if os.path.isfile(p):
                return p
    except Exception:
        pass
    hits = sorted(glob.glob(os.path.join(LT_DIR, "*", "languagetool-server.jar")), reverse=True)
    if hits:
        return hits[0]
    p = os.path.join(LT_DIR, "languagetool-server.jar")
    return p if os.path.isfile(p) else None


def lt_version():
    jar = find_jar()
    if not jar:
        return None
    m = re.search(r"LanguageTool-([\w.]+)", jar)
    return m.group(1) if m else "?"


_java = {"checked": False, "path": None, "version": None}


def _java_major(exe):
    try:
        p = subprocess.run([exe, "-version"], stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=20,
                           creationflags=NO_WINDOW)
    except Exception:
        return None, None
    out = (p.stderr + p.stdout).decode("utf-8", "replace")
    m = re.search(r'version "(\d+)(?:\.(\d+))?[^"]*"', out)
    if not m:
        return None, None
    major = int(m.group(1))
    if major == 1 and m.group(2):  # 1.8.0 -> 8
        major = int(m.group(2))
    return major, m.group(0)


def java_candidates():
    c = []
    for d in sorted(glob.glob(os.path.join(TOOLS, "jre*")) + glob.glob(os.path.join(TOOLS, "jdk*")), reverse=True):
        c.append(os.path.join(d, "bin", "java.exe"))
    jh = os.environ.get("JAVA_HOME")
    if jh:
        c.append(os.path.join(jh, "bin", "java.exe"))
    pf = [os.environ.get("ProgramFiles", r"C:\Program Files"), os.environ.get("ProgramFiles(x86)", "")]
    for root in pf:  # real JDK/JRE folders before PATH (Oracle's javapath\java.exe is a launcher shim)
        if not root:
            continue
        for vendor in ("Java", "Eclipse Adoptium", "Microsoft", "Zulu", "Amazon Corretto", "BellSoft", "Semeru"):
            for d in sorted(glob.glob(os.path.join(root, vendor, "*")), reverse=True):
                c.append(os.path.join(d, "bin", "java.exe"))
    w = shutil.which("java")
    if w:
        c.append(w)
    seen, out = set(), []
    for p in c:
        k = os.path.normcase(os.path.abspath(p))
        if k not in seen and os.path.isfile(p):
            seen.add(k)
            out.append(p)
    return out


def find_java():
    """First java.exe with version >= 17, or None. Cached."""
    if _java["checked"]:
        return _java["path"]
    for exe in java_candidates():
        major, ver = _java_major(exe)
        if major and major >= 17:
            _java.update(path=exe, version=ver)
            break
        if major:
            _info("languagetool: skipping %s (%s, need Java 17+)", exe, ver)
    _java["checked"] = True
    return _java["path"]


def installed():
    """LanguageTool can be used: the jar and a Java 17+ runtime are present (the server may not be running yet)."""
    return bool(find_jar() and find_java()) and not _state["broken"]


# ---------------------------------------------------------------------------------------------- process
_state = {"proc": None, "port": None, "broken": False, "fail_t": 0.0, "job": None}
_lock = threading.Lock()


def _free_port():
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


def _kill_on_close_job(pid):
    """Put the child in a job object that kills it when this process exits (even on a hard kill)."""
    try:
        import ctypes
        from ctypes import wintypes
        k32 = ctypes.WinDLL("kernel32", use_last_error=True)

        class IO_COUNTERS(ctypes.Structure):
            _fields_ = [(n, ctypes.c_ulonglong) for n in ("r", "w", "o", "rb", "wb", "ob")]

        class BASIC(ctypes.Structure):
            _fields_ = [("PerProcessUserTimeLimit", ctypes.c_longlong), ("PerJobUserTimeLimit", ctypes.c_longlong),
                        ("LimitFlags", wintypes.DWORD), ("MinimumWorkingSetSize", ctypes.c_size_t),
                        ("MaximumWorkingSetSize", ctypes.c_size_t), ("ActiveProcessLimit", wintypes.DWORD),
                        ("Affinity", ctypes.c_size_t), ("PriorityClass", wintypes.DWORD), ("SchedulingClass", wintypes.DWORD)]

        class EXTENDED(ctypes.Structure):
            _fields_ = [("Basic", BASIC), ("Io", IO_COUNTERS), ("ProcessMemoryLimit", ctypes.c_size_t),
                        ("JobMemoryLimit", ctypes.c_size_t), ("PeakProcessMemoryUsed", ctypes.c_size_t),
                        ("PeakJobMemoryUsed", ctypes.c_size_t)]

        k32.CreateJobObjectW.restype = wintypes.HANDLE
        k32.OpenProcess.restype = wintypes.HANDLE
        job = k32.CreateJobObjectW(None, None)
        if not job:
            return None
        info = EXTENDED()
        info.Basic.LimitFlags = 0x2000  # JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
        if not k32.SetInformationJobObject(wintypes.HANDLE(job), 9, ctypes.byref(info), ctypes.sizeof(info)):
            return None
        h = k32.OpenProcess(0x0100 | 0x0001, False, pid)  # PROCESS_SET_QUOTA | PROCESS_TERMINATE
        if not h:
            return None
        ok = k32.AssignProcessToJobObject(wintypes.HANDLE(job), wintypes.HANDLE(h))
        k32.CloseHandle(wintypes.HANDLE(h))
        return job if ok else None  # keep the handle open for the life of this process
    except Exception:
        return None


def _alive():
    p = _state["proc"]
    return p is not None and p.poll() is None


def _url():
    return "http://127.0.0.1:%d" % _state["port"]


def _ping(timeout=1.0):
    try:
        r = requests.get(_url() + "/v2/languages", timeout=timeout)
        return r.status_code == 200
    except Exception:
        return False


def start(wait=60.0):
    """Start the server if needed; returns its base URL or None. Thread-safe."""
    with _lock:
        if _alive():
            return _url()
        if _state["broken"]:
            return None
        if _state["fail_t"] and time.time() - _state["fail_t"] < 120:  # do not retry a failing start on every call
            return None
        jar, java = find_jar(), find_java()
        if not jar or not java:
            _state["fail_t"] = time.time()
            if not jar:
                _warn("languagetool: languagetool-server.jar not found under %s", LT_DIR)
            else:
                _warn("languagetool: no Java 17+ found (candidates: %s)", java_candidates())
            return None
        port = _free_port()
        os.makedirs(LOG_DIR, exist_ok=True)
        out = open(os.path.join(LOG_DIR, "languagetool.log"), "ab")
        args = [java, "-Xmx1g", "-Dfile.encoding=UTF-8", "-cp", jar, "org.languagetool.server.HTTPServer",
                "--port", str(port), "--allow-origin"]
        t0 = time.time()
        try:
            proc = subprocess.Popen(args, cwd=os.path.dirname(jar), stdin=subprocess.DEVNULL, stdout=out,
                                    stderr=subprocess.STDOUT, creationflags=NO_WINDOW)
        except OSError as e:
            _warn("languagetool: could not start java: %s", e)
            _state["fail_t"] = time.time()
            return None
        finally:
            out.close()
        _state.update(proc=proc, port=port, job=_kill_on_close_job(proc.pid))
        _info("languagetool %s starting: pid %d port %d (%s)", lt_version(), proc.pid, port, java)
        while time.time() - t0 < wait:
            if proc.poll() is not None:
                _warn("languagetool exited during start-up (code %s); see logs/languagetool.log", proc.returncode)
                _state.update(proc=None, fail_t=time.time())
                return None
            if _ping(0.5):
                _info("languagetool ready in %.1fs", time.time() - t0)
                return _url()
            time.sleep(0.25)
        _warn("languagetool did not answer within %.0fs; stopping it", wait)
        _stop_locked()
        _state["fail_t"] = time.time()
        return None


def _stop_locked():
    p = _state["proc"]
    _state["proc"] = None
    if p is None or p.poll() is not None:
        return
    try:  # by PID only (the whole tree of this one process), never by image name
        subprocess.run(["taskkill", "/PID", str(p.pid), "/T", "/F"], stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL, timeout=10, creationflags=NO_WINDOW)
    except Exception:
        pass
    try:
        p.kill()
    except Exception:
        pass


def stop():
    with _lock:
        _stop_locked()


atexit.register(stop)


def prestart():
    """Background start so the first correction does not wait for the JVM (about 3-10 s)."""
    def run():
        if start():
            for lang, s in (("en", "This is a test."), ("ja", "これはテストです。")):
                check(lang, s, timeout=30)  # each language loads its rules on first use (~1-3 s)
    if find_jar() and find_java():
        threading.Thread(target=run, daemon=True, name="lt-start").start()


def running():
    return _alive()


# ---------------------------------------------------------------------------------------------- check
# categories that are style/typography only: a learner's spoken sentence is not judged on these
DROP_CATEGORIES = {"CASING", "PUNCTUATION", "TYPOGRAPHY", "STYLE", "REDUNDANCY", "PLAIN_ENGLISH", "WIKIPEDIA",
                   "GENDER_NEUTRALITY", "REPETITIONS_STYLE", "TEXT_ANALYSIS", "CREATIVE_WRITING"}
DROP_RULES = {"WHITESPACE_RULE", "COMMA_PARENTHESIS_WHITESPACE", "UPPERCASE_SENTENCE_START", "EN_QUOTES",
              "DOUBLE_PUNCTUATION", "PUNCTUATION_PARAGRAPH_END", "SENTENCE_WHITESPACE", "EN_UNPAIRED_BRACKETS",
              "UNLIKELY_OPENING_PUNCTUATION", "EN_CONTRACTION_SPELLING", "I_LOWERCASE", "ENGLISH_WORD_REPEAT_BEGINNING_RULE",
              "EN_SPECIFIC_CASE", "EN_UPPER_CASE_NGRAM", "PROFANITY", "CONSECUTIVE_SPACES", "ZERO_WIDTH_SPACE"}


def check(lang, text, timeout=8.0):
    """Raw LanguageTool matches, or None if the server is not available."""
    base = start()
    if not base:
        return None
    try:
        r = requests.post(base + "/v2/check", data={"text": text, "language": LANG_CODE[lang]}, timeout=timeout)
    except Exception as e:
        _warn("languagetool check failed: %s", e)
        return None
    if r.status_code != 200:
        _warn("languagetool HTTP %s: %s", r.status_code, r.text[:200])
        return None
    return r.json().get("matches", [])


def _keep(m, text):
    rule = m.get("rule") or {}
    cat = (rule.get("category") or {}).get("id", "")
    rid = rule.get("id", "")
    if cat in DROP_CATEGORIES or rid in DROP_RULES:
        return False
    if not m.get("replacements"):
        return False
    off, ln = m.get("offset", 0), m.get("length", 0)
    orig = text[off:off + ln]
    rep = m["replacements"][0].get("value", "")
    if rep == orig:
        return False
    if orig.lower() == rep.lower() and orig.strip() and rep.strip():  # capitalization only
        return False
    if re.search(r"[가-힣]", orig):  # Korean mixed in: leave it to the AI
        return False
    if rid.startswith(("MORFOLOGIK", "HUNSPELL")) or cat == "TYPOS":
        # spelling: do not "correct" names (capitalized word that is not the first word) or very short tokens
        if orig[:1].isupper() and text[:off].strip():
            return False
    if UNRELIABLE_RE.search(rid):
        return False
    pos = _pick(m, text)
    rep = m["replacements"][pos].get("value", "")
    if _swaps_pronoun(orig, rep) or _changes_name(text, off, orig, rep):
        return False
    return True


# LanguageTool rules whose first suggestion is often wrong for a learner's sentence: they swap a pronoun by its case
# ("Me and him goes" -> "I and him goes", "Me is Tom" -> "I is Tom", "Them are" -> "Then are") without seeing the whole
# structure. Better no LanguageTool fix than a worse one (the AI, when available, checks the sentence itself).
UNRELIABLE_RE = re.compile(r"CONFUSION_OF_(ME|MY|I|HE|HIM|SHE|HER|WE|US|THEM|THEY)(_|$)|PRP_AT_SENT_START|"
                           r"^SENT_START_(THEM|ME|HIM|HER|US)$|NOMINATIVE|ACCUSATIVE|^PRONOUN_CASE")
WORD_RE = re.compile(r"[A-Za-z][A-Za-z'’]*")
PRONOUNS = frozenset("i me my mine myself he him his himself she her hers herself they them their theirs we us our ours "
                     "you your yours it its".split())


def _swaps_pronoun(orig, rep):
    """The suggestion replaces one pronoun by another (case/person swap)."""
    a = [w.lower() for w in WORD_RE.findall(orig)]
    b = [w.lower() for w in WORD_RE.findall(rep)]
    gone = [w for w in a if w not in b]
    new = [w for w in b if w not in a]
    return any(w in PRONOUNS for w in gone) and any(w in PRONOUNS for w in new)


def _changes_name(text, off, orig, rep):
    """The suggestion removes a capitalized word that is not at the start of a sentence (a name, a place, a title)."""
    kept = set(WORD_RE.findall(rep))
    for mm in WORD_RE.finditer(orig):
        w = mm.group(0)
        if w in kept or not w[0].isupper() or re.fullmatch(r"I(['’](m|d|ll|ve))?", w):
            continue
        before = text[:off + mm.start()].rstrip()
        if before and before[-1] not in ".!?:\"“(":
            return True
    return False


PAST_TIME_EN = re.compile(r"\b(yesterday|ago|last (night|week|weekend|month|year|summer|winter|spring|fall|autumn|time|"
                          r"monday|tuesday|wednesday|thursday|friday|saturday|sunday)|in (19|20)\d\d)\b", re.I)
IRREGULAR_PAST = set("""was were did had went came saw ate drank made took got gave found thought told bought brought ran
wrote met left felt kept began sang swam sat stood understood knew spoke read heard said paid sent spent lost won
became broke chose drove fell flew forgot froze grew hid held hurt let lay led meant put rode rang rose sold shook
shot shut slept stole struck taught threw wore woke""".split())
# rules whose first suggestion is often a different word; prefer the one that only changes the word form
PREFER_INFLECTION = {"HAD_TWO"}


def _looks_past(rep):
    w = rep.strip().lower().split()
    return bool(w) and (w[0] in IRREGULAR_PAST or w[0].endswith("ed"))


def _pick(m, text):
    """Index of the replacement to use (the first, unless a clear signal says otherwise)."""
    reps = [r.get("value", "") for r in m["replacements"][:4]]
    rid = (m.get("rule") or {}).get("id", "")
    if len(reps) > 1 and PAST_TIME_EN.search(text) and not _looks_past(reps[0]):
        for i, r in enumerate(reps):
            if _looks_past(r):
                m["_past"] = True  # "He go ... yesterday" -> went (not goes)
                return i
    if len(reps) > 1 and rid in PREFER_INFLECTION:
        orig = text[m["offset"]:m["offset"] + m["length"]].lower().split()
        for i, r in enumerate(reps):
            rw = r.lower().split()
            if len(rw) == len(orig) and all(b.startswith(a) for a, b in zip(orig, rw)):
                return i
    return 0


def apply(text, matches):
    """Apply one replacement (normally the first) of each kept match: non-overlapping, right to left."""
    chosen, end = [], -1
    for m in sorted(matches, key=lambda m: (m["offset"], -m["length"])):
        if m["offset"] >= end:
            m["_rep"] = m["replacements"][_pick(m, text)]["value"]
            chosen.append(m)
            end = m["offset"] + m["length"]
    out = text
    for m in sorted(chosen, key=lambda m: m["offset"], reverse=True):
        out = out[:m["offset"]] + m["_rep"] + out[m["offset"] + m["length"]:]
    return out, chosen


# Korean explanations. Specific rule ids first, then rule-id patterns, then the LanguageTool category.
KO_PAST = "어제·지난주처럼 지난 일을 말할 때는 과거형을 써요."
KO_RULES = {
    "EN_A_VS_AN": "모음 소리로 시작하는 말 앞에는 a 대신 an을 써요.",
    "HE_VERB_AGR": "he/she/it 뒤의 현재형 동사는 -s 형태(goes, does, has)를 써요.",
    "NON3PRS_VERB": "I/you/we/they 뒤나 조동사(can, will) 뒤에는 -s 없는 동사원형을 써요.",
    "I_AM_VB": "agree, like 같은 일반동사 앞에는 am/is/are를 쓰지 않아요.",
    "MISSING_TO_BEFORE_A_VERB": "want, need 뒤에 다른 동사가 오면 to를 붙여요 (want to go).",
    "BE_INTEREST_IN": "감정을 느끼는 사람은 -ed(interested), 감정을 주는 것은 -ing(interesting)를 써요.",
    "ADMIT_ENJOY_VB": "look forward to, enjoy 뒤의 동사는 -ing 형태로 써요.",
    "HAD_TWO": "two 이상의 수 뒤에는 복수 명사(-s)를 써요.",
    "KOREWA": "'~은/는'의 は는 'wa'로 읽지만 글자는 わ가 아니라 は로 써요.",
    "SHE_DONT": "he/she/it에는 don't 대신 doesn't를 써요.",
    "DOES_NOT_AGREEMENT": "he/she/it에는 don't 대신 doesn't를 써요.",
    "I_AM_AGREE": "agree는 동사라서 am 없이 I agree라고 해요.",
    "BE_AGREE": "agree는 동사라서 be동사 없이 써요 (I agree).",
    "GO_TO_HOME": "home은 '집으로'라는 뜻이 있어서 앞에 to를 쓰지 않아요.",
    "TO_HOME": "home은 '집으로'라는 뜻이 있어서 앞에 to를 쓰지 않아요.",
    "DID_BASEFORM": "did 뒤에는 동사원형을 써요.",
    "MD_BASEFORM": "can/will/should 같은 조동사 뒤에는 동사원형을 써요.",
    "TO_NON_BASE": "to 뒤에는 동사원형을 써요.",
    "THE_SUPERLATIVE": "최상급 앞에는 the를 써요.",
    "DT_DT": "관사가 겹쳤어요. 하나만 써요.",
    "MANY_NN": "many 뒤에는 복수 명사를 써요.",
    "MUCH_COUNTABLE": "셀 수 있는 명사에는 much 대신 many를 써요.",
    "A_PLURAL": "a/an 뒤에는 단수 명사를 써요.",
    "THIS_NNS": "this/that 뒤에는 단수, these/those 뒤에는 복수 명사를 써요.",
    "ENGLISH_WORD_REPEAT_RULE": "같은 단어가 두 번 반복됐어요.",
    "IT_IS": "'it is'의 줄임말은 it's, 소유격은 its예요.",
    "YOUR_YOU_RE": "your(너의)와 you're(you are)를 구분해요.",
    "THERE_THEIR": "there/their/they're를 구분해요.",
}
KO_PATTERNS = [
    (r"A_VS_AN|_AN_|ARTICLE|^A_|_DT_|^DT_|_THE_|THE_", "관사(a/an/the)를 고쳤어요."),
    (r"AGREEMENT|_AGR|SVA|NON3PRS|3SG|PERS_PRONOUN|SINGULAR|PLURAL|NNS|_DONT|DOESNT|HAVE_HAS|WAS_WERE",
     "주어와 동사의 수(단수/복수)를 맞춰요."),
    (r"PAST|TENSE|PERFECT|PARTICIPLE|BASEFORM|_VBD|_VBN|_VBZ|_VBG|_VB_|GERUND|INFINITIVE|BEEN_PART|HAVE_PART|PRP_VB",
     "동사의 형태나 시제를 고쳤어요."),
    (r"PREP", "전치사를 고쳤어요."),
    (r"ORDER", "단어 순서를 고쳤어요."),
    (r"REPEAT|DUPLICATE", "같은 말이 반복됐어요."),
]
SPELL_RE = re.compile(r"MORFOLOGIK|HUNSPELL|SPELL|^TYPO")   # real spelling rules; LanguageTool's TYPOS category also
                                                              # holds word-confusion rules that are not spelling
KO_CATEGORIES = {
    "TYPOS": "헷갈리기 쉬운 단어를 바로잡았어요.",
    "STYLE": "표현을 더 자연스럽게 고쳤어요.",
    "REDUNDANCY": "군더더기를 줄였어요.",
    "CONFUSED_WORDS": "헷갈리기 쉬운 단어를 바로잡았어요.",
    "COLLOCATIONS": "함께 쓰는 단어 조합을 자연스럽게 고쳤어요.",
    "GRAMMAR": "문법을 고쳤어요.",
    "NONSTANDARD_PHRASES": "표준 표현으로 고쳤어요.",
    "SEMANTICS": "뜻이 맞도록 고쳤어요.",
    "MISC": "문법을 고쳤어요.",
}
KO_JA = [  # Japanese rule ids are few; match by keyword
    (r"WA$|PARTICLE|JOSHI|助詞", "조사를 고쳤어요."),
    (r"SPELL|TYPO|MORFOLOGIK", "표기를 고쳤어요."),
]
KO_DEFAULT = "문법을 고쳤어요."


def explain(lang, m):
    rule = m.get("rule") or {}
    rid = rule.get("id", "").upper()
    cat = (rule.get("category") or {}).get("id", "")
    if m.get("_past"):
        return KO_PAST
    if rid in KO_RULES:
        return KO_RULES[rid]
    if lang != "ja" and SPELL_RE.search(rid):
        return "철자를 고쳤어요."
    for pat, ko in (KO_JA if lang == "ja" else []) + KO_PATTERNS:
        if re.search(pat, rid):
            return ko
    return KO_CATEGORIES.get(cat, KO_DEFAULT)


MAX_ROUNDS = 2   # a second pass may fix what the first fix uncovered ("He go" -> "He goes" ... ); never more


def correct(lang, text):
    """LanguageTool correction of one learner sentence.
    Returns {"fix", "fix_ko", "changes": [{"from", "to", "rule", "category", "ko"}]} or None.
    None also when the corrected sentence would still be flagged by LanguageTool itself after MAX_ROUNDS passes: a
    dubious fix is worse than none (the AI, when available, then checks the original sentence)."""
    if lang not in LANG_CODE or not text.strip():
        return None
    t0 = time.time()
    matches = check(lang, text)
    if matches is None:
        return None
    cur, changes, raw_n = text, [], len(matches)
    for rnd in range(MAX_ROUNDS + 1):
        kept = [m for m in matches if _keep(m, cur)]
        if not kept:
            break
        if rnd == MAX_ROUNDS:   # still flagged after the fixes: do not offer a half-fixed sentence
            _info("languagetool %s: fixed sentence %r is still flagged -> no fix %.2fs", lang, cur, time.time() - t0)
            return None
        fixed, chosen = apply(cur, kept)
        if fixed.strip() == cur.strip():
            break
        for m in chosen:
            rule = m.get("rule") or {}
            changes.append({"from": cur[m["offset"]:m["offset"] + m["length"]], "to": m["_rep"], "rule": rule.get("id", ""),
                            "category": (rule.get("category") or {}).get("id", ""), "ko": explain(lang, m)})
        cur = fixed
        matches = check(lang, cur)
        if matches is None:   # LanguageTool went away between the calls: keep what we have
            break
    if not changes or cur.strip() == text.strip():
        _info("languagetool %s: no fix (%d raw matches) %.2fs", lang, raw_n, time.time() - t0)
        return None
    seen_ko, parts = set(), []
    for c in changes:
        if c["ko"] not in seen_ko and len(parts) < 3:
            seen_ko.add(c["ko"])
            parts.append("'%s' → '%s': %s" % (c["from"].strip() or "(없음)", c["to"].strip() or "(빼기)", c["ko"]))
    _info("languagetool %s: %d fix(es) %s %.2fs", lang, len(changes), [c["rule"] for c in changes], time.time() - t0)
    return {"fix": cur, "fix_ko": " / ".join(parts), "changes": changes}


def status():
    return {"installed": bool(find_jar()), "java": _java["path"] if _java["checked"] else None,
            "running": _alive(), "version": lt_version()}
