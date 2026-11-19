# -*- coding: utf-8 -*-
"""PA5a: fit the phone's score calibration (docs/v201_design.md 2.4, docs/v200_phone_design.md 1.6).

The phone transcribes with whisper.cpp (token probability of the sampled token); the PC server scores with faster-whisper (forced
alignment probability, beam 5). The distributions differ, so the phone's word probability `p` is mapped to the PC's with a monotone
piecewise-linear map (`p_map`), the word threshold `ok_prob` is searched, and (only as the last fallback, --fit-final) the final
score gets a monotone map too (`final_map`).

  calib_fit.py --pc <pc.json> [more.json ...] --phone <phone.json> [more.json ...] --out-params <json> --report <json>
               [--holdout 0.3] [--seed 7] [--fit-final]

Inputs (written by calib_pc_run.py and godot\\tools\\calib_phone.gd; clips are joined by `id`, never by position):
  pc.json    {"v":1,"kind":"pc","date":"YYYY-MM-DD","clips":[{id, sentence_id, group("synth"|"user"), variant, voice, target, text,
                words:[{w,p,start,end}], duration, score:<server score_en result>}]}
  phone.json {"v":1,"kind":"phone","status":"ok","model":"<file name>","beam":1,"clips":[{id, ok(must be true), error, text, duration,
                words:[{w,p,start,end}], ms}]}   (a file with status "fail", or a clip with ok false, is "CALIB_FAIL data")

What it does: split the SENTENCES (not the clips) 70 / 30 with --seed, fit on the 70 %, judge on the 30 %:
  p_map     isotonic regression (pool adjacent violators) of the PC `p` on the phone `p`, over the words that BOTH engines matched
            exactly (the server's own alignment), read at 10 fixed points (P_MAP_X)
  ok_prob   the word threshold that makes the phone's per-word `ok` agree most with the PC's `ok` (ties: closest to 0.45)
  judging   the server's `score_en` is called in this process on the mapped phone words (nothing is copied here)
Gates (GATES below, holdout only): word ok agreement synth >= 0.85 / user >= 0.80, final score MAE <= 10 and p90 <= 20, fluency
MAE <= 15, wrong clip below its clean clip in >= 95 % of the pairs, wrong clips scoring 70+ <= 10 %, clean clips under 70 <= 10 %.
Below a gate (none is waived): "CALIB_FAIL <metric> ..." and exit 1 and --out-params is NOT written (--report is). Bad data (not one agreed pair of
files, empty, a clip on one side only, pairing agreement < 0.6): "CALIB_FAIL <input|pairing|data|agreement>" and exit 1.
Exit code: 0 fitted and every gate passed, 1 failed, 2 usage error (argparse) or an --out-params / --report path inside a repository, a
worktree or backend (nothing is written).
The phone words are cleaned with the D-1 time rule (clean_word_times, docs 8.1) before they are scored, as the app does.

The report holds numbers only (counts, metrics, intervals); no sentence, no transcript. Nothing is written but --out-params and --report.
Safety: no network, no server process, nothing is written under backend\\ (the server is imported in this process; see load_server()).
"""
import argparse
import atexit
import contextlib
import datetime
import difflib
import json
import math
import os
import random
import re
import shutil
import socket
import sys
import tempfile

sys.dont_write_bytecode = True   # no __pycache__ under backend\\ or next to this file

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
BACKEND = os.path.join(ROOT, "backend")

SEED = 7
HOLDOUT = 0.3
P_MAP_X = [0.0, 0.05, 0.1, 0.2, 0.3, 0.45, 0.6, 0.75, 0.9, 1.0]
OK_PROB_DEFAULT = 0.45
OK_PROB_GRID = [round(0.21 + 0.01 * k, 2) for k in range(59)]   # 0.21 .. 0.79 (the phone reads ok_prob only inside (0.2, 0.8))
PASS_SCORE = 70
MIN_PAIR_AGREEMENT = 0.6      # below this the two files are not the same recordings
MIN_FIT_PAIRS = 10            # word pairs needed to fit p_map
CLEAN_VARIANTS = ("clean", "user_clean")
WRONG_VARIANTS = ("wrong", "user_wrong")
# (metric, op, limit, group): the gate for a group that has no clip at all is skipped ("SKIP"), a group with clips but no holdout data fails
GATES = (
    ("ok_agree_synth", ">=", 0.85, "synth"),
    ("ok_agree_user", ">=", 0.80, "user"),
    ("score_mae", "<=", 10.0, None),
    ("score_p90", "<=", 20.0, None),
    ("fluency_mae", "<=", 15.0, None),
    ("wrong_lower_pairs", ">=", 0.95, None),
    ("wrong_pass_rate", "<=", 0.10, None),
    ("clean_fail_rate", "<=", 0.10, None),
)


# the tools write ONLY below the folder the user names with --out, and never inside a repository / worktree / backend (recordings and
# transcripts must not land in a place that is committed or shared): these roots, and the repo that holds this file, are refused
FORBIDDEN_ROOTS = ("D:\\Ai\\언어\\app", "D:\\Ai\\언어\\app_wt")
RETIME = True                  # D-1 word time cleanup before the phone words are scored (tests and the before/after measure turn it off)
MODEL_FILE_RE = re.compile(r"^ggml-[A-Za-z0-9._-]{1,60}\.bin$")
DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")


class CalibError(Exception):
    """a failure that ends the run with `CALIB_FAIL <code>` and exit 1 (the message never holds a sentence or a transcript)"""

    def __init__(self, code, msg=""):
        Exception.__init__(self, "%s: %s" % (code, msg))
        self.code = code
        self.msg = msg


# ------------------------------------------------------------------------------------------------ where the tools may write
def _norm_path(p):
    return os.path.normcase(os.path.abspath(os.fspath(p)))


def out_path_refused(path):
    """True when `path` (made absolute, `..` resolved, links followed) is, or lies inside, a repository / worktree / backend folder"""
    try:
        cands = {_norm_path(path), os.path.normcase(os.path.realpath(os.fspath(path)))}
    except (OSError, ValueError, TypeError):
        return True
    bases = {_norm_path(b) for b in FORBIDDEN_ROOTS + (ROOT, BACKEND)}
    bases |= {os.path.normcase(os.path.realpath(b)) for b in (ROOT, BACKEND)}
    for c in cands:
        for b in bases:
            if c == b or c.startswith(b + os.sep):
                return True
    return False


class OutPathRefused(Exception):
    """a path the tool was told to write lies inside a repository / worktree / backend (the message never holds the path)"""


def require_out_paths(*paths):
    """raise OutPathRefused unless every path may be written"""
    if refuse_out_paths(paths) is not None:
        raise OutPathRefused()


def refuse_out_paths(paths):
    """the first path that may not be written, or None (the caller prints its own `<TOOL>_FAIL out_path` line and exits 2)"""
    for p in paths:
        if out_path_refused(p):
            return p
    return None


# ------------------------------------------------------------------------------------------------ the map rules (docs/v201_design.md 2.1)
def _is_num(x):
    return isinstance(x, (int, float)) and not isinstance(x, bool) and math.isfinite(x)


def _valid_map(m, x_max, y_max):
    """2..32 points [x, y]; x strictly increasing from 0 to x_max (both present); y non-decreasing inside 0..y_max"""
    if not isinstance(m, (list, tuple)) or not (2 <= len(m) <= 32):
        return False
    prev_x = prev_y = None
    for pt in m:
        if not isinstance(pt, (list, tuple)) or len(pt) != 2 or not _is_num(pt[0]) or not _is_num(pt[1]):
            return False
        x, y = float(pt[0]), float(pt[1])
        if x < 0.0 or x > x_max or y < 0.0 or y > y_max:
            return False
        if prev_x is not None and (x <= prev_x or y < prev_y):
            return False
        prev_x, prev_y = x, y
    return float(m[0][0]) == 0.0 and float(m[-1][0]) == float(x_max)


def valid_p_map(p_map):
    return _valid_map(p_map, 1.0, 1.0)


def valid_final_map(m):
    return _valid_map(m, 100.0, 100.0)


def _interp(t, m):
    """piecewise linear through the points of m, the end value outside"""
    if t <= m[0][0]:
        return float(m[0][1])
    if t >= m[-1][0]:
        return float(m[-1][1])
    for (x0, y0), (x1, y1) in zip(m, m[1:]):
        if t <= x1:
            return float(y0) + (float(y1) - float(y0)) * (t - float(x0)) / (float(x1) - float(x0))
    return float(m[-1][1])


def map_p(p, p_map):
    """docs/v201_design.md 2.1: NaN -> 0, p cut to [0,1]; then t=(p-x0)/(x1-x0), y=y0+(y1-y0)*t inside the segment, the end value
    outside the points; a map that is not valid leaves p alone"""
    p = float(p) if _is_num(p) else 0.0
    p = min(1.0, max(0.0, p))
    if not valid_p_map(p_map):
        return p
    return _interp(p, p_map)


def map_final(score, final_map):
    """same rule on the axis 0..100: floor(y + 0.5), then cut to 0..100; a map that is not valid leaves the score alone"""
    s = float(score) if _is_num(score) else 0.0
    s = min(100.0, max(0.0, s))
    if not valid_final_map(final_map):
        return int(math.floor(s + 0.5))
    y = _interp(s, final_map)
    return int(min(100, max(0, math.floor(y + 0.5))))


def clean_word_times(words, clip_sec):
    """D-1 (docs/v201_design.md 8.1), the one rule of the phone app and of these tools. words: [{w, p, start, end}] in transcription order,
    clip_sec: the length of the WAV in seconds. 1) a start / end that is not a finite number is 0; 2) start and end are cut to
    [0, clip_sec]; 3) from the first word on, start = max(start, the previous word's start); 4) end = max(end, start); 5) when a next word
    exists, end = min(end, the next word's cleaned start), and an end below start becomes start; 6) order, count, w and p stay, and the
    times are NOT rounded. Returns new dicts."""
    clip = float(clip_sec) if _is_num(clip_sec) and clip_sec > 0 else 0.0
    starts, ends = [], []
    for w in words:
        a = float(w["start"]) if _is_num(w.get("start")) else 0.0
        b = float(w["end"]) if _is_num(w.get("end")) else 0.0
        a, b = min(clip, max(0.0, a)), min(clip, max(0.0, b))
        if starts:
            a = max(a, starts[-1])
        b = max(b, a)
        starts.append(a)
        ends.append(b)
    for i in range(len(ends) - 1):
        ends[i] = min(ends[i], starts[i + 1])
        if ends[i] < starts[i]:
            ends[i] = starts[i]
    return [dict(w, start=starts[i], end=ends[i]) for i, w in enumerate(words)]


# ------------------------------------------------------------------------------------------------ safety helpers and the server
@contextlib.contextmanager
def no_network():
    """socket creation and name lookup raise inside this block (nothing in this tool may reach the network)"""
    def _blocked(*a, **k):
        raise RuntimeError("network access is blocked while the calibration tools run")
    saved = (socket.socket.__init__, socket.getaddrinfo, socket.create_connection)
    socket.socket.__init__ = _blocked
    socket.getaddrinfo = _blocked
    socket.create_connection = _blocked
    try:
        yield
    finally:
        socket.socket.__init__, socket.getaddrinfo, socket.create_connection = saved


def _under(path, base):
    try:
        p = os.path.abspath(os.fspath(path))
    except Exception:
        return False
    b = os.path.abspath(base)
    return p == b or p.startswith(b + os.sep)


@contextlib.contextmanager
def keep_backend_clean():
    """importing server.py calls os.makedirs for backend\\models\\hf, logs and cache: those calls are skipped (nothing is created
    under backend\\)"""
    real = os.makedirs

    def makedirs(name, mode=0o777, exist_ok=False):
        if _under(name, BACKEND):
            return None
        return real(name, mode, exist_ok)
    os.makedirs = makedirs
    try:
        yield
    finally:
        os.makedirs = real


def model_home():
    """the folder with the local models (HF cache): <repo>\\backend\\models\\hf, or, when this checkout has none (a worktree: the
    folder is not tracked), the one of the checkout that owns the interpreter (<X>\\backend\\.venv -> <X>\\backend\\models\\hf)"""
    for home in (os.path.join(BACKEND, "models", "hf"),
                 os.path.join(os.path.dirname(os.path.abspath(sys.prefix)), "models", "hf")):
        try:
            if os.path.isdir(home) and os.listdir(home):
                return home
        except OSError:
            pass
    return None


_SERVER = {"mod": None}


def load_server(work_dir=None):
    """import backend\\server.py once in this process (no port is opened: only a server PROCESS does that). Reads the local models only.
    work_dir (optional) holds what the server writes while synthesizing (the espeak data copy and the TTS cache), never backend\\.
    The speech-to-text device is CPU/int8, the same as `server.py --stt-cpu`."""
    if _SERVER["mod"] is not None:
        return _SERVER["mod"]
    sys.dont_write_bytecode = True
    if work_dir:
        work = os.path.abspath(work_dir)
    else:
        work = tempfile.mkdtemp(prefix="hoehwa_calib_")
        atexit.register(shutil.rmtree, work, True)   # nothing is left behind in the temp folder
    os.makedirs(work, exist_ok=True)
    os.environ["HOEHWA_ESPEAK_DIR"] = os.path.join(work, "espeak")
    os.environ["LANG_TTS_CACHE_DIR"] = os.path.join(work, "tts_cache")
    saved_argv = sys.argv
    sys.argv = [saved_argv[0], "--stt-cpu", "--tag", "calib"]   # server.py reads sys.argv for --stt-cpu / --port / --tag
    if BACKEND not in sys.path:
        sys.path.insert(0, BACKEND)
    try:
        with keep_backend_clean():
            import server
    finally:
        sys.argv = saved_argv
    home = model_home()
    if home:
        server.HF_DIR = home
        for k in ("HF_HOME", "HF_HUB_CACHE"):
            os.environ[k] = home
    os.environ["HF_HUB_OFFLINE"] = "1"   # Kokoro (huggingface_hub) must never look at the network, whatever the caller's environment says
    os.environ["TRANSFORMERS_OFFLINE"] = "1"

    def _load_whisper_local(device, compute_type):
        """server._load_whisper with local_files_only=True spelled out (the model files are only read, never fetched)"""
        from faster_whisper import WhisperModel
        import numpy as np
        m = WhisperModel(server.CFG["stt"]["model"], device=device, compute_type=compute_type,
                         download_root=os.path.join(server.HF_DIR, "whisper"), local_files_only=True)
        segs, _info = m.transcribe(np.zeros(16000, dtype=np.float32), language="en", beam_size=1)
        list(segs)
        return m
    server._load_whisper = _load_whisper_local
    _SERVER["mod"] = server
    return server


@contextlib.contextmanager
def ok_prob_as(S, value):
    """the server's score_en reads the module constant OK_PROB at call time: set it for one call and put it back"""
    saved = S.OK_PROB
    S.OK_PROB = float(value)
    try:
        yield
    finally:
        S.OK_PROB = saved


# ------------------------------------------------------------------------------------------------ reading the files
def _clean_words(raw, where):
    """`where` is a position ("file 2, clip 17"), never a clip id or a file name: error texts must not carry what the user's files say"""
    if not isinstance(raw, list):
        raise CalibError("input", "%s: words is not a list" % where)
    out = []
    for w in raw:
        if (not isinstance(w, dict) or not isinstance(w.get("w"), str) or not _is_num(w.get("p"))
                or not _is_num(w.get("start")) or not _is_num(w.get("end"))):
            raise CalibError("input", "%s: a word without w/p/start/end" % where)
        out.append({"w": w["w"], "p": min(1.0, max(0.0, float(w["p"]))), "start": float(w["start"]), "end": float(w["end"])})
    return out


def read_run(path, kind, file_no=1):
    """one pc.json or phone.json -> (header dict, clips dict id -> clip). Errors name the file and the clip by NUMBER only."""
    try:
        with open(path, "r", encoding="utf-8-sig") as f:
            d = json.load(f)
    except (OSError, ValueError) as e:
        raise CalibError("input", "file %d cannot be read (%s)" % (file_no, type(e).__name__))
    if not isinstance(d, dict) or not isinstance(d.get("clips"), list):
        raise CalibError("input", "file %d has no clips list" % file_no)
    if d.get("status") == "fail":
        raise CalibError("data", "file %d is marked as a failed run" % file_no)
    clips = {}
    for n, c in enumerate(d["clips"], 1):
        where = "file %d, clip %d" % (file_no, n)
        if not isinstance(c, dict) or not isinstance(c.get("id"), str) or not c["id"]:
            raise CalibError("input", "%s: no id" % where)
        cid = c["id"]
        if cid in clips:
            raise CalibError("input", "%s: its id is used twice" % where)
        rec = {"id": cid, "words": _clean_words(c.get("words"), where), "text": c.get("text") if isinstance(c.get("text"), str) else ""}
        if kind == "phone":
            if c.get("ok") is not True:
                raise CalibError("data", "%s: the phone could not transcribe it" % where)
            if not _is_num(c.get("duration")) or c["duration"] < 0:
                raise CalibError("input", "%s: no clip length" % where)
            rec["duration"] = float(c["duration"])
        if kind == "pc":
            if not isinstance(c.get("target"), str) or not isinstance(c.get("score"), dict) or not isinstance(c["score"].get("units"), list):
                raise CalibError("input", "%s: no target / score" % where)
            sc = c["score"]
            if not _is_num(sc.get("score")) or not _is_num(sc.get("fluency")):
                raise CalibError("input", "%s: score without score / fluency" % where)
            for u in sc["units"]:
                if not isinstance(u, dict) or not isinstance(u.get("ok"), bool):
                    raise CalibError("input", "%s: a unit without ok" % where)
            rec.update(target=c["target"], score=sc, group=c.get("group") if c.get("group") in ("synth", "user") else "synth",
                       variant=str(c.get("variant", "")), voice=str(c.get("voice", "")),
                       sentence_id=str(c.get("sentence_id") or c["target"]))
        clips[cid] = rec
    return d, clips


def read_runs(paths, kind):
    """several files of one kind -> (headers, merged clips); the same id in two files is an error"""
    heads, merged = [], {}
    for no, p in enumerate(paths, 1):
        h, clips = read_run(p, kind, no)
        heads.append(h)
        for cid, c in clips.items():
            if cid in merged:
                raise CalibError("input", "file %d has a clip id that an earlier file already used" % no)
            merged[cid] = c
    return heads, merged


def join_clips(pc, phone):
    """(pc clip, phone clip) pairs ordered by clip id; BY ID, never by position. A clip on one side only is an error."""
    only_pc = sorted(set(pc) - set(phone))
    only_phone = sorted(set(phone) - set(pc))
    if only_pc or only_phone:
        raise CalibError("pairing", "clips on one side only (pc only %d, phone only %d)" % (len(only_pc), len(only_phone)))
    return [(pc[i], phone[i]) for i in sorted(pc)]


# ------------------------------------------------------------------------------------------------ word tables (the server's own alignment)
def heard_words(S, words):
    """[(normalized word, p)] the same way score_en builds `hw`"""
    hw = []
    for w in words:
        for x in S.en_words(w["w"]):
            hw.append((x, w["p"]))
    return hw


def exact_ps(S, target, words):
    """(target words, [p of the heard word that matched EXACTLY, else None]) with the server's align_seq"""
    tw = S.en_words(target)
    hw = heard_words(S, words)
    if not hw:
        return tw, [None] * len(tw)
    pairs, _ins = S.align_seq(tw, [x for x, _p in hw], S.word_sim)
    return tw, [hw[j][1] if (j is not None and exact) else None for (j, exact) in pairs]


def pair_agreement(S, rows):
    """how much the two engines heard the same words: mean over clips of the SequenceMatcher ratio of the two heard word lists
    (both empty = 1.0). Close to 1 for the same recordings, near 0 for clips that were paired wrongly."""
    if not rows:
        return 0.0
    tot = 0.0
    for pc, ph in rows:
        a = [x for x, _p in heard_words(S, pc["words"])]
        b = [x for x, _p in heard_words(S, ph["words"])]
        tot += difflib.SequenceMatcher(None, a, b, autojunk=False).ratio()
    return tot / len(rows)


def sentence_key(S, pc, cache=None):
    """the group a clip's sentence belongs to: the target as the SERVER's scoring sees it (en_words), so two ids with the same words,
    case or punctuation are one sentence. A clip without a target falls back to its sentence id."""
    t = pc.get("target")
    if isinstance(t, str) and t:
        if cache is not None and t in cache:
            return cache[t]
        words = S.en_words(t) if S is not None else re.findall(r"[a-z0-9']+", t.lower())   # no server loaded: lower case words
        key = "t:" + " ".join(words)
        if cache is not None:
            cache[t] = key
        if key != "t:":
            return key
    return "id:" + str(pc.get("sentence_id"))


def split_sentences(rows, seed=SEED, holdout=HOLDOUT, S=None):
    """(train rows, holdout rows). The split is by SENTENCE: every clip of a sentence (all voices, variants, and the user's clips of the
    same sentence) goes to one side, so no sentence is in both. "Same sentence" = the same words after the server's normalization
    (sentence_key), not only the same id."""
    S = S or _SERVER["mod"]   # the server's en_words when it is loaded (the tool always has it); else plain lower case words
    cache = {}
    keyed = [(sentence_key(S, pc, cache), (pc, ph)) for pc, ph in rows]
    keys = sorted({k for k, _r in keyed})
    if len(keys) < 2:
        raise CalibError("data", "need at least 2 sentences to split into fit and holdout")
    rng = random.Random(seed)
    rng.shuffle(keys)
    n_hold = min(len(keys) - 1, max(1, int(round(len(keys) * holdout))))
    hold = set(keys[:n_hold])
    train = [r for k, r in keyed if k not in hold]
    held = [r for k, r in keyed if k in hold]
    return train, held


# ------------------------------------------------------------------------------------------------ fitting
def isotonic_blocks(points):
    """pool-adjacent-violators for a non-decreasing fit of y on x. points: [(x, y, weight)]. Equal x are pooled first.
    Returns [(x center, y fit)] with x increasing and y non-decreasing."""
    acc = {}
    for x, y, w in points:
        a = acc.setdefault(float(x), [0.0, 0.0])
        a[0] += float(y) * w
        a[1] += w
    stack = []   # [sum w*x, sum w*y, sum w]
    for x in sorted(acc):
        swy, w = acc[x]
        stack.append([x * w, swy, w])
        while len(stack) >= 2 and stack[-2][1] / stack[-2][2] > stack[-1][1] / stack[-1][2]:
            top = stack.pop()
            stack[-1][0] += top[0]
            stack[-1][1] += top[1]
            stack[-1][2] += top[2]
    return [(b[0] / b[2], b[1] / b[2]) for b in stack]


def fit_p_map(pairs, xs=P_MAP_X):
    """pairs: [(phone p, pc p)] -> p_map at the fixed points xs (flat outside the data, linear between the block centers)"""
    if len(pairs) < MIN_FIT_PAIRS:
        raise CalibError("data", "only %d matched word pairs (need %d)" % (len(pairs), MIN_FIT_PAIRS))
    blocks = isotonic_blocks([(a, b, 1.0) for a, b in pairs])
    out = []
    for x in xs:
        y = _interp(x, blocks)
        out.append([x, round(min(1.0, max(0.0, y)), 4)])
    if not valid_p_map(out):
        raise CalibError("data", "the fitted p_map is not valid")
    return out


def word_rows(S, rows):
    """per clip: (pc ok list, phone exact p list); the PC ok is the server's own `ok` stored in the pc file"""
    out = []
    for n, (pc, ph) in enumerate(rows, 1):
        tw, ps = exact_ps(S, pc["target"], ph["words"])
        units = pc["score"]["units"]
        if len(units) != len(tw):
            raise CalibError("input", "clip %d (in id order): the score units do not match the target" % n)
        out.append(([bool(u["ok"]) for u in units], ps))
    return out


def matched_pairs(S, rows):
    """[(phone p, pc p)] over the target words that both engines matched exactly"""
    out = []
    for pc, ph in rows:
        _tw, ps_pc = exact_ps(S, pc["target"], pc["words"])
        _tw, ps_ph = exact_ps(S, pc["target"], ph["words"])
        for a, b in zip(ps_ph, ps_pc):
            if a is not None and b is not None:
                out.append((a, b))
    return out


def ok_agreement(items):
    """items: [(pc ok, phone ok)] over target words -> share that agree (0.0 when empty)"""
    if not items:
        return 0.0
    return sum(1 for a, b in items if a == b) / float(len(items))


def fit_ok_prob(wrows, p_map):
    """the threshold in OK_PROB_GRID with the highest per-word agreement (ties: closest to 0.45, then the smaller)"""
    mapped = [([a for a in oks], [None if p is None else map_p(p, p_map) for p in ps]) for oks, ps in wrows]
    best = None
    for t in OK_PROB_GRID:
        n = k = 0
        for oks, ps in mapped:
            for a, p in zip(oks, ps):
                n += 1
                if a == (p is not None and p >= t):
                    k += 1
        score = k / float(n) if n else 0.0
        key = (-score, abs(t - OK_PROB_DEFAULT), t)
        if best is None or key < best[0]:
            best = (key, t)
    return best[1]


def phone_result(S, pc, ph, p_map, ok_prob, final_map=None):
    """the server's score_en on the mapped phone words (a copy of the result; `score` goes through final_map when given)"""
    words = clean_word_times(ph["words"], ph.get("duration", 0.0)) if RETIME else ph["words"]
    mapped = [{"w": w["w"], "p": map_p(w["p"], p_map), "start": w["start"], "end": w["end"]} for w in words]
    with ok_prob_as(S, ok_prob):
        r = S.score_en(pc["target"], mapped, ph["text"])
    r = dict(r)
    if final_map is not None:
        r["score"] = map_final(r["score"], final_map)
    return r


def final_map_step(a):
    """a monotone map under which raw score a is the lowest raw score that reaches 70 (raw a-1 stays below), and every other raw
    score stays as it is where it can: below 70 it is the identity up to the step, above it the identity again. No x twice."""
    if a == PASS_SCORE:
        return [[0, 0], [100, 100]]
    if a < PASS_SCORE:
        pts = [[0, 0]] if a >= 1 else [[0, PASS_SCORE]]
        if a >= 2:
            pts.append([a - 1, a - 1])
        if a >= 1:
            pts.append([a, PASS_SCORE])
        pts.append([PASS_SCORE, PASS_SCORE])
        pts.append([100, 100])
        return pts
    pts = [[0, 0], [PASS_SCORE - 1, PASS_SCORE - 1], [a - 1, PASS_SCORE - 1], [a, a]]
    if a < 100:
        pts.append([100, 100])
    return pts


def fit_final_map(S, rows, p_map, ok_prob):
    """the last fallback: a monotone map of the final score under which the wrong clips of `rows` score 70+ and the clean clips
    score under 70 in at most 10 % each. One step at the raw score `a` (final_map_step), chosen to make the worse of the two rates
    smallest (ties: nearest 70, then the smaller). Returns the map or None when no step reaches the 10 % limit."""
    clean, wrong = [], []
    for pc, ph in rows:
        if pc["variant"] not in CLEAN_VARIANTS and pc["variant"] not in WRONG_VARIANTS:
            continue
        s = phone_result(S, pc, ph, p_map, ok_prob)["score"]
        (clean if pc["variant"] in CLEAN_VARIANTS else wrong).append(s)
    if not clean or not wrong:
        return None
    best = None
    for a in range(0, 101):
        wp = sum(1 for s in wrong if s >= a) / float(len(wrong))
        cf = sum(1 for s in clean if s < a) / float(len(clean))
        key = (max(wp, cf), abs(a - PASS_SCORE), a)
        if best is None or key < best[0]:
            best = (key, a)
    (worst, _d, _a), a = best
    if worst > 0.10:
        return None
    m = final_map_step(a)
    return m if valid_final_map(m) else None


# ------------------------------------------------------------------------------------------------ judging
def wilson(k, n, z=1.96):
    """95 % Wilson interval of a share k/n"""
    if n <= 0:
        return [0.0, 1.0]
    p = k / float(n)
    d = 1.0 + z * z / n
    c = (p + z * z / (2.0 * n)) / d
    h = z * math.sqrt(p * (1.0 - p) / n + z * z / (4.0 * n * n)) / d
    return [round(max(0.0, c - h), 4), round(min(1.0, c + h), 4)]


def percentile90(values):
    """nearest-rank 90th percentile (the value at rank ceil(0.9 n))"""
    if not values:
        return None
    v = sorted(values)
    return v[min(len(v) - 1, max(0, int(math.ceil(0.9 * len(v))) - 1))]


def evaluate(S, rows, p_map, ok_prob, final_map=None):
    """all the numbers the gates need, over `rows`"""
    word_items = {"synth": [], "user": [], "all": []}
    diffs, fl_diffs = [], []
    by_key = {}   # (sentence, voice) -> {"clean": score, "wrong": score}
    wrong_scores, clean_scores = [], []
    for n, (pc, ph) in enumerate(rows, 1):
        r = phone_result(S, pc, ph, p_map, ok_prob, final_map)
        units = pc["score"]["units"]
        if len(units) != len(r["units"]):
            raise CalibError("input", "clip %d (in id order): the score units do not match the target" % n)
        for a, b in zip(units, r["units"]):
            word_items[pc["group"]].append((bool(a["ok"]), bool(b["ok"])))
            word_items["all"].append((bool(a["ok"]), bool(b["ok"])))
        diffs.append(abs(r["score"] - pc["score"]["score"]))
        fl_diffs.append(abs(r["fluency"] - pc["score"]["fluency"]))
        slot = by_key.setdefault((pc["sentence_id"], pc["voice"]), {})
        if pc["variant"] in CLEAN_VARIANTS:
            slot["clean"] = r["score"]
            clean_scores.append(r["score"])
        elif pc["variant"] in WRONG_VARIANTS:
            slot["wrong"] = r["score"]
            wrong_scores.append(r["score"])
    pairs = [s for s in by_key.values() if "clean" in s and "wrong" in s]
    m = {
        "clips": len(rows),
        "words": {g: len(v) for g, v in word_items.items()},
        "ok_agree_synth": ok_agreement(word_items["synth"]) if word_items["synth"] else None,
        "ok_agree_user": ok_agreement(word_items["user"]) if word_items["user"] else None,
        "ok_agree_all": ok_agreement(word_items["all"]) if word_items["all"] else None,
        "score_mae": (sum(diffs) / len(diffs)) if diffs else None,
        "score_p90": percentile90(diffs),
        "fluency_mae": (sum(fl_diffs) / len(fl_diffs)) if fl_diffs else None,
        "pair_count": len(pairs),
        "wrong_lower_pairs": (sum(1 for s in pairs if s["wrong"] < s["clean"]) / float(len(pairs))) if pairs else None,
        "wrong_clips": len(wrong_scores),
        "wrong_pass_rate": (sum(1 for s in wrong_scores if s >= PASS_SCORE) / float(len(wrong_scores))) if wrong_scores else None,
        "clean_clips": len(clean_scores),
        "clean_fail_rate": (sum(1 for s in clean_scores if s < PASS_SCORE) / float(len(clean_scores))) if clean_scores else None,
    }
    m["ci95"] = {}
    for g in ("synth", "user"):
        v = word_items[g]
        if v:
            m["ci95"]["ok_agree_" + g] = wilson(sum(1 for a, b in v if a == b), len(v))
    return m


def judge(metrics, groups_present):
    """[{name, op, limit, value, result}] with result "OK" | "FAIL" | "SKIP" (a group that has no clip at all). No gate is waived (D-2)."""
    out = []
    for name, op, limit, group in GATES:
        value = metrics.get(name)
        if group is not None and group not in groups_present:
            result = "SKIP"
        elif value is None:
            result = "FAIL"   # the group is there but the holdout has nothing to measure: not proven, not passed
        elif op == ">=":
            result = "OK" if value >= limit else "FAIL"
        else:
            result = "OK" if value <= limit else "FAIL"
        out.append({"name": name, "op": op, "limit": limit, "value": value, "result": result})
    return out


def model_id_from_file(name):
    """ggml-base.en-q5_1.bin -> whisper-base.en-q5_1"""
    s = os.path.basename(str(name or ""))
    if s.startswith("ggml-"):
        s = s[5:]
    if s.endswith(".bin"):
        s = s[:-4]
    return "whisper-" + s if s else ""


def _round(v, n=4):
    return None if v is None else round(float(v), n)


def _write_json(path, obj):
    d = os.path.dirname(os.path.abspath(path))
    os.makedirs(d, exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        json.dump(obj, f, ensure_ascii=False, indent=1)
        f.write("\n")


# ------------------------------------------------------------------------------------------------ the tool
def run(args, S=None, out=print):
    """returns the exit code; every outcome is a `CALIB_OK` / `CALIB_FAIL ...` line"""
    refused = refuse_out_paths([args.out_params, args.report])
    if refused is not None:
        out("CALIB_FAIL out_path")
        out("  --out-params / --report may not be inside a repository, a worktree or backend")
        return 2
    S = S or load_server()
    try:
        pc_heads, pc = read_runs(args.pc, "pc")
        ph_heads, ph = read_runs(args.phone, "phone")
        if not pc and not ph:
            raise CalibError("data", "no clips")
        if not pc or not ph:
            raise CalibError("pairing", "one of the two sides has no clips")
        rows = join_clips(pc, ph)
        betas = {h.get("beam") for h in ph_heads}
        models = {h.get("model") for h in ph_heads}
        if len(betas) != 1 or len(models) != 1:
            raise CalibError("input", "the phone files were not made with the same beam and model")
        beam = betas.pop()
        if isinstance(beam, bool) or not isinstance(beam, int) or beam not in (1, 2, 3):
            raise CalibError("input", "phone beam must be 1, 2 or 3")
        model_name = models.pop()
        if not isinstance(model_name, str) or not MODEL_FILE_RE.match(model_name):
            raise CalibError("input", "the phone model name is not an allowed ggml file name")
        model_id = model_id_from_file(model_name)
        date = None
        for h in pc_heads:
            d = h.get("date")
            if d is None:
                continue
            try:
                if not isinstance(d, str) or not DATE_RE.match(d):
                    raise ValueError
                datetime.date.fromisoformat(d)
            except ValueError:
                raise CalibError("input", "the pc date is not a valid YYYY-MM-DD date")
            date = date or d
        agree = pair_agreement(S, rows)
        if agree < MIN_PAIR_AGREEMENT:
            raise CalibError("agreement", "pairing agreement %.3f < %.2f (the phone clips are not the PC clips)" % (agree, MIN_PAIR_AGREEMENT))
        train, held = split_sentences(rows, args.seed, args.holdout, S)
        pairs = matched_pairs(S, train)
        p_map = fit_p_map(pairs)
        wrows = word_rows(S, train)
        ok_prob = fit_ok_prob(wrows, p_map)
        final_map = None
        fallback = "beam" if beam > 1 else "none"
        if args.fit_final:
            final_map = fit_final_map(S, train, p_map, ok_prob)
            fallback = "final_map"
        metrics = evaluate(S, held, p_map, ok_prob, final_map)
        groups = {pc_clip["group"] for pc_clip, _p in rows}
        gates = judge(metrics, groups)
    except CalibError as e:
        out("CALIB_FAIL %s" % e.code)
        out("  %s" % e.msg)
        if getattr(args, "report", None):
            _write_json(args.report, {"v": 1, "status": "fail", "failed": [e.code], "reason": e.msg})
        return 1
    for g in gates:
        out("  %s %s %s %s -> %s" % (g["name"], "-" if g["value"] is None else "%.4f" % g["value"], g["op"], g["limit"], g["result"]))
    if args.fit_final and final_map is None:
        out("  final_map: no step keeps both rates under 10 %")
    failed = [g["name"] for g in gates if g["result"] == "FAIL"]
    date = date or datetime.date.today().isoformat()
    report = {
        "v": 1, "status": "fail" if failed else "ok", "failed": failed, "date": date, "seed": args.seed, "holdout": args.holdout,
        "model_id": model_id, "beam": beam, "fallback": fallback, "retime": bool(RETIME),
        "clips": {"total": len(rows), "synth": sum(1 for r in rows if r[0]["group"] == "synth"),
                  "user": sum(1 for r in rows if r[0]["group"] == "user"), "fit": len(train), "holdout": len(held)},
        "sentences": {"fit": len({r[0]["sentence_id"] for r in train}), "holdout": len({r[0]["sentence_id"] for r in held})},
        "pair_agreement": _round(agree),
        "fit": {"matched_word_pairs": len(pairs), "ok_prob": ok_prob, "p_map": p_map, "final_map": final_map},
        "holdout_metrics": {k: (_round(v) if isinstance(v, float) else v) for k, v in metrics.items()},
        "gates": [dict(g, value=_round(g["value"])) for g in gates],
    }
    if args.report:
        _write_json(args.report, report)
    if failed:
        out("CALIB_FAIL " + " ".join(failed))
        return 1
    synth_clips, user_clips = report["clips"]["synth"], report["clips"]["user"]
    params = {
        "v": 1, "model_id": model_id, "calibrated": True, "date": date, "ok_prob": ok_prob, "beam": beam,
        "p_map": p_map, "final_map": final_map if final_map is not None else [[0, 0], [100, 100]],
        "report": {
            "synth_clips": synth_clips, "user_clips": user_clips,
            "ok_agree_synth": _round(metrics["ok_agree_synth"]), "ok_agree_user": _round(metrics["ok_agree_user"]),
            "score_mae": _round(metrics["score_mae"]), "score_p90": _round(metrics["score_p90"]),
            "fluency_mae": _round(metrics["fluency_mae"]), "wrong_lower_pairs": _round(metrics["wrong_lower_pairs"]),
            "wrong_pass_rate": _round(metrics["wrong_pass_rate"]), "clean_fail_rate": _round(metrics["clean_fail_rate"]),
            "fallback": fallback,
        },
    }
    if args.out_params:
        _write_json(args.out_params, params)
    out("CALIB_OK clips=%d holdout=%d ok_prob=%.2f fallback=%s" % (len(rows), len(held), ok_prob, fallback))
    return 0


def build_parser():
    ap = argparse.ArgumentParser(description="fit the phone score calibration (p_map, ok_prob, beam, final_map) against the PC server")
    ap.add_argument("--pc", nargs="+", required=True, help="pc.json from calib_pc_run.py (several files are merged)")
    ap.add_argument("--phone", nargs="+", required=True, help="phone.json from calib_phone.gd (several files are merged)")
    ap.add_argument("--out-params", required=True, help="score_params.json to write (only when every gate passes)")
    ap.add_argument("--report", required=True, help="report json (numbers only; written also when a gate fails)")
    ap.add_argument("--holdout", type=float, default=HOLDOUT, help="share of the sentences kept for judging (default 0.3)")
    ap.add_argument("--seed", type=int, default=SEED)
    ap.add_argument("--fit-final", action="store_true", help="last fallback: also fit a monotone final_map (docs 2.4 step 3)")
    return ap


def main(argv=None):
    args = build_parser().parse_args(argv)
    if not (0.0 < args.holdout < 1.0):
        print("--holdout must be between 0 and 1")
        return 2
    try:
        with no_network():
            return run(args)
    except CalibError as e:   # load_server problems and the like
        print("CALIB_FAIL %s" % e.code)
        print("  %s" % e.msg)
        return 1
    except Exception as e:   # only the type: an exception text may carry what a file said
        print("CALIB_FAIL internal (%s)" % type(e).__name__)
        return 1


if __name__ == "__main__":
    sys.exit(main())
