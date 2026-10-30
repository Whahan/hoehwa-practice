# -*- coding: utf-8 -*-
"""Tests for song_align.py (song study K2). Pure functions: no server, no models.
Run:  <venv>\\python.exe -I backend\\test_song_align.py        (last line: == test_song_align: N passed, 0 failed ==)
All lyrics here are invented for the tests (no real song text).
"""
import ast
import os
import random
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

import song_align as sa  # noqa: E402

PASSED, FAILED = [], []


def ok(name, cond, detail=""):
    (PASSED if cond else FAILED).append(name)
    print(("  PASS " if cond else "  FAIL ") + name + ("" if cond else "  -> " + str(detail)))


def inv(name, lines, duration):
    """K2-7: invariants checked on every produced result."""
    bad = sa.check_lines(lines, duration)
    ok("invariants: " + name, not bad, bad[:3])


def words_at(words, start, step=0.5, length=0.4):
    return [{"w": w, "s": round(start + k * step, 3), "e": round(start + k * step + length, 3), "p": 0.9}
            for k, w in enumerate(words)]


class Reader:
    """Stand-in for server.ja_to_kata: a tiny dictionary (kanji -> katakana), anything else kept."""
    MAP = {"君": "キミ", "好": "ス", "言": "イ", "夜": "ヨル", "空": "ソラ", "歌": "ウタ"}

    def __call__(self, text):
        return "".join(self.MAP.get(c, c) for c in text)


# ------------------------------------------------------------------------------------------------------------------
print("[tokens / keys]")
ok("en key drops punctuation and case", sa.normalize_key("Don't!", "en") == "dont")
ok("en key curly apostrophe", sa.normalize_key("don’t", "en") == "dont")
ok("empty / punctuation-only key", sa.normalize_key("--", "en") == "" and sa.normalize_key(None, "en") == "")
ok("ja key folds hiragana to katakana", sa.normalize_key("きみ", "ja") == "キミ")
ok("ja key drops long mark and small tsu", sa.normalize_key("らーめん", "ja") == "ラメン" and sa.normalize_key("きって", "ja") == "キテ")
ok("ja key uses the reader", sa.normalize_key("君", "ja", Reader()) == "キミ")
ok("ja key keeps kanji without a reader", sa.normalize_key("君", "ja") == "君")
ok("broken reader falls back", sa.normalize_key("きみ", "ja", lambda t: 1 / 0) == "キミ")
toks = sa.tokenize_line("Hold on -- we're (almost) there!", "en")
ok("en tokenize strips edge punctuation", [t["w"] for t in toks] == ["Hold", "on", "we're", "almost", "there"], toks)
ok("ja tokenize by script runs", [t["w"] for t in sa.tokenize_line("君が好きだと言えなくて", "ja", Reader())]
   == ["君", "が", "好", "きだと", "言", "えなくて"])
ok("provided tokens win", [t["w"] for t in sa.tokenize_line("x y", "en", tokens=[{"w": "ab"}, {"w": "cd"}])] == ["ab", "cd"])

# ------------------------------------------------------------------------------------------------------------------
print("[golden 1 english: 3 misrecognised + 2 missing]")
LYR1 = [{"text": "the river runs beside the old house", "t": None, "p": 0},
        {"text": "we sing until morning comes", "t": None, "p": 1}]
TRUTH = "the river runs beside the old house we sing until morning comes".split()
asr1 = words_at(["river", "runs", "besides", "the", "house", "we", "sing", "until", "mourning", "comes"], 10.0)
# "the"(0) and "old"(5) missing; "river"->"rival" far, "beside"->"besides" near, "morning"->"mourning" near
asr1[0]["w"] = "rival"
D1 = 40.0
r1 = sa.align_lyrics(LYR1, asr1, D1, "en")
ok("golden1: 12 lyric words total", r1["total"] == 12, r1["total"])
ok("golden1: anchor match rate >= 0.75", r1["match_rate"] >= 0.75, r1["match_rate"])
ok("golden1: no low_match warning", "low_match" not in r1["warnings"], r1["warnings"])
allw = [w for ln in r1["lines"] for w in ln["words"]]
ok("golden1: 12 words out in lyric order", [w["w"] for w in allw] == TRUTH, [w["w"] for w in allw])
ok("golden1: word times monotone", all(allw[k]["s"] <= allw[k + 1]["s"] and allw[k]["e"] <= allw[k + 1]["e"] for k in range(11)))
by = {(k, w["w"]): w for k, w in enumerate(allw)}
exact = {(2, "runs"): asr1[1], (3, "beside"): asr1[2], (6, "house"): asr1[4], (7, "we"): asr1[5], (8, "sing"): asr1[6],
         (9, "until"): asr1[7], (10, "morning"): asr1[8], (11, "comes"): asr1[9]}
same = all(by[k]["s"] == v["s"] and by[k]["e"] == v["e"] and by[k]["est"] is False for k, v in exact.items())
ok("golden1: matched words carry the recognised time and est False", same)
ok("golden1: misrecognised far word and omitted words are est", by[(1, "river")]["est"] and by[(0, "the")]["est"] and by[(5, "old")]["est"])
inv("golden1", r1["lines"], D1)
ok("golden1: line fields", all(set(ln) >= {"i", "p", "t0", "t1", "text", "conf", "est", "stale", "words"} for ln in r1["lines"])
   and [ln["p"] for ln in r1["lines"]] == [0, 1] and r1["lines"][0]["text"] == LYR1[0]["text"])
ok("golden1: timing is word, no est_times", r1["timing"] == "word" and "est_times" not in r1["warnings"])

asr1b = words_at(["river", "runs", "besides", "the", "house", "we", "sing", "until", "mourning", "comes"], 10.0)
r1b = sa.align_lyrics(LYR1, asr1b, D1, "en")
ok("golden1b: near misrecognitions count as anchors (10/12)", r1b["anchored"] == 10 and r1b["match_rate"] >= 0.83, r1b["match_rate"])
inv("golden1b", r1b["lines"], D1)

asr_exact = words_at(TRUTH, 5.0)
rx = sa.align_lyrics(LYR1, asr_exact, 30.0, "en")
ok("exact recognition: rate 1.0, nothing est", rx["match_rate"] == 1.0 and not any(w["est"] for ln in rx["lines"] for w in ln["words"]))
ok("exact recognition: line t0/t1 are first/last word", rx["lines"][0]["t0"] == 5.0 and rx["lines"][0]["t1"] == 8.4, rx["lines"][0])
inv("exact", rx["lines"], 30.0)

# ------------------------------------------------------------------------------------------------------------------
print("[golden 2 japanese: kana reading alignment]")
LYR2 = [{"text": "君が好きだと言えなくて", "t": None, "p": 0}]
asr2 = [{"w": "きみ", "s": 4.0, "e": 4.6}, {"w": "が", "s": 4.6, "e": 4.9}, {"w": "すき", "s": 5.0, "e": 5.6},
        {"w": "だと", "s": 5.6, "e": 6.1}, {"w": "いえ", "s": 6.2, "e": 6.8}, {"w": "なくて", "s": 6.8, "e": 7.6}]
r2 = sa.align_lyrics(LYR2, asr2, 20.0, "ja", Reader())
ok("golden2: 君 matches きみ through the reader (rate 1.0)", r2["match_rate"] == 1.0, r2["match_rate"])
w2 = r2["lines"][0]["words"]
ok("golden2: words are the lyric tokens, none est", [w["w"] for w in w2] == ["君", "が", "好", "きだと", "言", "えなくて"]
   and not any(w["est"] for w in w2), w2)
ok("golden2: 君 starts where きみ starts", w2[0]["s"] == 4.0 and w2[0]["e"] <= 4.6)
ok("golden2: line spans the recognised words", r2["lines"][0]["t0"] == 4.0 and r2["lines"][0]["t1"] == 7.6)
inv("golden2", r2["lines"], 20.0)
r2n = sa.align_lyrics(LYR2, asr2, 20.0, "ja", None)
ok("golden2: without a reader kanji cannot match, kana still do (0 < rate < 1)", 0.3 < r2n["match_rate"] < 1.0, r2n["match_rate"])
inv("golden2 no reader", r2n["lines"], 20.0)
asr2h = [{"w": "ヨルノソラ", "s": 1.0, "e": 2.5}]
r2h = sa.align_lyrics([{"text": "夜の空"}], asr2h, 10.0, "ja", Reader())
ok("golden2: katakana vs kanji+hiragana lyric (夜の空 = ヨルノソラ)", r2h["match_rate"] == 1.0, r2h["match_rate"])
r2t = sa.align_lyrics([{"text": "君が好きだと言えなくて", "tokens": [{"w": "君", "kata": "キミ"}, {"w": "が"}, {"w": "好き", "kata": "スキ"},
                                                    {"w": "だ"}, {"w": "と"}, {"w": "言えない", "kata": "イエナイ"}]}], asr2, 20.0, "ja")
ok("golden2: K4 tokens give the output words and the readings", [w["w"] for w in r2t["lines"][0]["words"]] == ["君", "が", "好き", "だ", "と", "言えない"]
   and r2t["match_rate"] > 0.8, r2t["match_rate"])
inv("golden2 tokens", r2t["lines"], 20.0)
ok("golden2: a lone matching kana is not an anchor (3-run rule)",
   sa.align_lyrics([{"text": "あいうえお"}], [{"w": "かきあくけ", "s": 1.0, "e": 2.0}], 10.0, "ja")["anchored"] == 0)

# ------------------------------------------------------------------------------------------------------------------
print("[interpolation, extrapolation]")
LYR4 = [{"text": "alpha bravo charlie delta echo foxtrot golf hotel india juliet", "p": 0}]
asr4 = [{"w": "bravo", "s": 10.0, "e": 10.5}, {"w": "charlie", "s": 10.6, "e": 11.2}, {"w": "india", "s": 14.0, "e": 14.5}]
r4 = sa.align_lyrics(LYR4, asr4, 30.0, "en")
w4 = r4["lines"][0]["words"]
ok("interp: anchors keep est False, others est True", [w["est"] for w in w4] == [True, False, False, True, True, True, True, True, False, True], [w["est"] for w in w4])
ok("interp: words between anchors lie between them", all(11.2 <= w["s"] and w["e"] <= 14.0 for w in w4[3:8]), w4)
ok("interp: leading word ends where the first anchor starts, trailing starts at last anchor end",
   w4[0]["e"] == 10.0 and w4[9]["s"] == 14.5, (w4[0], w4[9]))
ok("interp: times stay inside [0, duration]", all(0.0 <= w["s"] <= w["e"] <= 30.0 for w in w4))
inv("interp", r4["lines"], 30.0)
asr4e = [{"w": "bravo", "s": 0.3, "e": 0.8}, {"w": "juliet", "s": 29.0, "e": 29.9}]
r4e = sa.align_lyrics([{"text": "one two three four five six bravo seven eight juliet"}], asr4e, 30.0, "en")
ok("extrapolation near the edges stays inside [0, 30]", all(0.0 <= w["s"] <= w["e"] <= 30.0 for w in r4e["lines"][0]["words"]), r4e["lines"][0]["words"][:2])
inv("extrapolation edges", r4e["lines"], 30.0)
r4g = sa.align_lyrics([{"text": "aaa bbb"}, {"text": "ccc ddd"}, {"text": "eee fff"}],
                      [{"w": "bbb", "s": 5.0, "e": 5.5}, {"w": "eee", "s": 9.0, "e": 9.5}], 20.0, "en")
ok("anchors in different lines: unmatched line sits between them", r4g["lines"][1]["t0"] >= 5.5 and r4g["lines"][1]["t1"] <= 9.0, r4g["lines"][1])
inv("anchors across lines", r4g["lines"], 20.0)
r4d = sa.align_lyrics([{"text": "late words here"}], [{"w": "here", "s": 59.0, "e": 59.9}], 60.0, "en")
inv("anchor at the very end", r4d["lines"], 60.0)

# ------------------------------------------------------------------------------------------------------------------
print("[wrong / odd input]")
r6a = sa.align_lyrics(LYR1, [], 60.0, "en")
ok("K2-6 empty recognition: no exception, 2 lines, low_match", len(r6a["lines"]) == 2 and "low_match" in r6a["warnings"], r6a["warnings"])
ok("K2-6 empty recognition: lines spread over the whole length in order", r6a["lines"][0]["t0"] == 0.0 and r6a["lines"][1]["t1"] == 60.0
   and r6a["lines"][0]["t1"] <= r6a["lines"][1]["t0"] + 1e-6, [(l["t0"], l["t1"]) for l in r6a["lines"]])
ok("K2-6 empty recognition: longer line gets the larger share", (r6a["lines"][0]["t1"] - r6a["lines"][0]["t0"]) > (r6a["lines"][1]["t1"] - r6a["lines"][1]["t0"]))
ok("K2-6 empty recognition: every word est, rate 0, timing est", all(w["est"] for ln in r6a["lines"] for w in ln["words"]) and r6a["match_rate"] == 0.0
   and r6a["timing"] == "est" and "est_times" in r6a["warnings"])
inv("empty recognition", r6a["lines"], 60.0)
r6b = sa.align_lyrics([], asr_exact, 60.0, "en")
ok("K2-6 empty lyrics: empty line list", r6b["lines"] == [] and r6b["total"] == 0)
ok("K2-6 empty lyrics and empty recognition", sa.align_lyrics([], [], 60.0)["lines"] == [])
other = words_at("zebra quartz mango violin tundra pencil harbor galaxy button window carpet lantern".split(), 3.0)
r6c = sa.align_lyrics(LYR1, other, 60.0, "en")
ok("K2-6 unrelated recognition: rate < 0.15 and low_match", r6c["match_rate"] < 0.15 and "low_match" in r6c["warnings"], (r6c["match_rate"], r6c["warnings"]))
ok("K2-6 unrelated recognition: every word est (F6)", all(w["est"] for ln in r6c["lines"] for w in ln["words"]))
ok("K2-6 unrelated recognition: lines placed in the recognised span", r6c["lines"][0]["t0"] >= 3.0 - 1e-6 and r6c["lines"][-1]["t1"] <= 9.0 + 1e-6,
   [(l["t0"], l["t1"]) for l in r6c["lines"]])
inv("unrelated recognition", r6c["lines"], 60.0)
ja_other = [{"w": "ほしぞらのした", "s": 1.0, "e": 3.0}, {"w": "あるいていく", "s": 3.0, "e": 5.0}]
r6j = sa.align_lyrics([{"text": "夜の空に歌を"}, {"text": "君が好きだと言えなくて"}], ja_other, 30.0, "ja", Reader())
ok("K2-6 unrelated japanese: rate < 0.15 and low_match", r6j["match_rate"] < 0.15 and "low_match" in r6j["warnings"], (r6j["match_rate"], r6j["warnings"]))
inv("unrelated japanese", r6j["lines"], 30.0)
junk = [None, 5, "x", {"w": "good", "s": "a", "e": 1}, {"w": None, "s": 1, "e": 2}, {"s": 1, "e": 2},
        {"w": "ok", "s": float("nan"), "e": 2}, {"w": "river", "s": 2.0, "e": 2.4}, {"w": "!!", "s": 3, "e": 4}]
try:
    rj = sa.align_lyrics([{"text": "the river"}, None, "", {"text": "  "}, 7], junk, 10.0, "en")
    ok("junk recognition entries are ignored, no exception", len(rj["lines"]) == 1 and rj["anchored"] == 1, rj)
    inv("junk input", rj["lines"], 10.0)
except Exception as exc:                                    # pragma: no cover
    ok("junk recognition entries are ignored, no exception", False, repr(exc))
rpun = sa.align_lyrics([{"text": "..."}, {"text": "la la la"}], words_at(["la", "la", "la"], 2.0), 10.0, "en")
ok("punctuation-only line stays a line with no words", len(rpun["lines"]) == 2 and rpun["lines"][0]["words"] == [] and rpun["lines"][0]["est"] is True)
inv("punctuation-only line", rpun["lines"], 10.0)
ok("duration 0 or None is survivable", len(sa.align_lyrics(LYR1, asr_exact, 0, "en")["lines"]) == 2 and len(sa.align_lyrics(LYR1, [], None, "en")["lines"]) == 2)
inv("duration missing", sa.align_lyrics(LYR1, asr_exact, None, "en")["lines"], 5.0 + 11 * 0.5 + 0.4 + 1.0)
rt = sa.align_lyrics(LYR1, words_at(TRUTH, 5.0, 0.5), 8.0, "en")
ok("recognised words past the end are dropped", all(w["e"] <= 8.0 for ln in rt["lines"] for w in ln["words"]) and "duration_mismatch" in rt["warnings"], rt["warnings"])
inv("words past the end", rt["lines"], 8.0)
rov = sa.align_lyrics([{"text": "one two three"}], [{"w": "one", "s": 1.0, "e": 2.0}, {"w": "two", "s": 1.5, "e": 2.2}, {"w": "three", "s": 1.2, "e": 1.3}], 10.0, "en")
inv("overlapping / unsorted recognised times", rov["lines"], 10.0)
rbig = sa.align_lyrics([{"text": "w%d" % k} for k in range(450)], [], 100.0, "en")
ok("more than 400 lines: cut with lyrics_truncated", len(rbig["lines"]) == 400 and "lyrics_truncated" in rbig["warnings"])
bad_inv = [{"t0": 5.0, "t1": 4.0, "words": []}, {"t0": 3.0, "t1": 9.0, "words": [{"w": "a", "s": 2.0, "e": 3.0}]},
           {"t0": 10.0, "t1": 99.0, "words": [{"w": "a", "s": 11.0, "e": 10.5}]}]
ok("check_lines catches broken lines (t0>=t1, order, word outside, s>e, past duration)", len(sa.check_lines(bad_inv, 50.0)) >= 5, sa.check_lines(bad_inv, 50.0))
ok("check_lines accepts a good line", sa.check_lines([{"t0": 1.0, "t1": 2.0, "words": [{"s": 1.0, "e": 1.5}]}], 5.0) == [])

# ------------------------------------------------------------------------------------------------------------------
print("[LRC line times]")


def lrc_lines(n=12, shift=0.0, start=10.0, gap=4.0):
    texts = ["the %s road leads home tonight" % w for w in
             "silver golden quiet narrow endless gentle broken hollow rolling distant crooked wandering".split()][:n]
    return [{"text": tx, "t": round(start + k * gap + shift, 3), "p": k // 4} for k, tx in enumerate(texts)]


def asr_for(lines, shift, jitter=0.0, seed=1, lang="en", reader=None):
    """Recognised words as the estimator models them (+ shift, + deterministic jitter)."""
    rnd = random.Random(seed)
    out = []
    ja = lang == "ja"
    for ln in lines:
        acc = 0.0
        for tk in sa.tokenize_line(ln["text"], lang, reader):
            s = ln["t"] + acc * (0.2 if ja else 0.07) + shift + rnd.uniform(-jitter, jitter)
            n = len(tk["key"])
            out.append({"w": tk["key"] if ja else tk["w"], "s": round(s, 3), "e": round(s + (0.2 * n if ja else 0.3), 3)})
            acc += n if ja else n + 1
    return out


L = lrc_lines()
for shift in (1.2, -0.8, 0.0, 3.4):
    est = sa.estimate_lrc_offset(L, asr_for(L, shift), "en")
    ok("K2-5 offset %+.1f recovered (+-0.1)" % shift, abs(est["offset"] - shift) <= 0.1 + 1e-9 and est["support"] >= 5, est)
est_j = sa.estimate_lrc_offset(L, asr_for(L, 1.2, jitter=0.15, seed=4), "en")
ok("K2-5 offset 1.2 with +-0.15 s jitter", abs(est_j["offset"] - 1.2) <= 0.1, est_j)
est_4 = sa.estimate_lrc_offset(L[:4], asr_for(L[:4], 1.2), "en")
ok("K2-5 fewer than 5 supporting lines -> offset 0", est_4["offset"] == 0.0 and est_4["support"] == 4, est_4)
est_5 = sa.estimate_lrc_offset(L[:5], asr_for(L[:5], 1.2), "en")
ok("K2-5 exactly 5 supporting lines is enough", abs(est_5["offset"] - 1.2) <= 0.1, est_5)
est_u = sa.estimate_lrc_offset(L, other, "en")
ok("offset: unrelated recognition -> 0 and low sample match", est_u["offset"] == 0.0 and est_u["sample_match"] < 0.3, est_u)
ok("offset: no recognition / no times -> 0", sa.estimate_lrc_offset(L, [], "en")["offset"] == 0.0
   and sa.estimate_lrc_offset([{"text": "a b c d"}], asr_for(L, 1.0), "en")["offset"] == 0.0)
ok("offset is clamped to +-5", abs(sa.estimate_lrc_offset(L, asr_for(L, 5.8), "en")["offset"]) <= 5.0)
sample = [w for w in asr_for(L, 1.2) if 16 <= w["s"] < 34 or 40 <= w["s"] < 56]
est_s = sa.estimate_lrc_offset(L, sample, "en")
ok("offset from sparse sample windows only", abs(est_s["offset"] - 1.2) <= 0.1 and est_s["sample_match"] > 0.7, est_s)
LJ = [{"text": t, "t": 5.0 + 3.5 * k} for k, t in enumerate(
    ["夜の空に歌を歌う", "君が好きだと言えなくて", "空の歌が夜に消える", "言えない夜の歌を聞く", "好きな空を君と見る", "夜の歌を空に返す"])]
est_ja = sa.estimate_lrc_offset(LJ, asr_for(LJ, -0.9, lang="ja", reader=Reader()), "ja", Reader())
ok("offset japanese (kana pairs)", abs(est_ja["offset"] + 0.9) <= 0.1 and est_ja["support"] >= 5, est_ja)

lr = sa.lines_from_lrc(L, 120.0, 0.0, "en")
ok("lrc: one line per lyric, line start = LRC time", len(lr["lines"]) == 12 and lr["lines"][0]["t0"] == 10.0 and lr["lines"][3]["t0"] == 22.0)
ok("lrc: words est True, timing line, est_times", all(w["est"] for ln in lr["lines"] for w in ln["words"]) and lr["timing"] == "line" and "est_times" in lr["warnings"])
ok("lrc: line ends at most at the next start", all(lr["lines"][k]["t1"] <= lr["lines"][k + 1]["t0"] + 1e-9 for k in range(11)))
ok("lrc: last line is capped (does not run to the end of a 120 s song)", lr["lines"][-1]["t1"] - lr["lines"][-1]["t0"] <= 12.0, lr["lines"][-1])
inv("lrc", lr["lines"], 120.0)
lo = sa.lines_from_lrc(L, 120.0, 1.2, "en", offset_guessed=True)
ok("lrc offset applied to every line and offset_guess warned", abs(lo["lines"][0]["t0"] - 11.2) < 1e-6 and "offset_guess" in lo["warnings"])
inv("lrc offset", lo["lines"], 120.0)
lneg = sa.lines_from_lrc(L, 120.0, -50.0, "en")
inv("lrc big negative offset", lneg["lines"], 120.0)
lend = sa.lines_from_lrc(L, 40.0, 0.0, "en")
ok("lrc lines past the duration -> duration_mismatch, still valid", "duration_mismatch" in lend["warnings"] or max(l["t0"] for l in L) <= 42)
inv("lrc past the end", lend["lines"], 40.0)
Lm = [dict(x) for x in L]
Lm[3]["t"] = None
Lm[4]["t"] = None
lm = sa.lines_from_lrc(Lm, 120.0, 0.0, "en")
ok("lrc: lines without a time are interpolated between neighbours", Lm[2]["t"] < lm["lines"][3]["t0"] < lm["lines"][4]["t0"] < Lm[5]["t"])
inv("lrc missing times", lm["lines"], 120.0)
lnone = sa.lines_from_lrc([{"text": "no time here"}, {"text": "none at all"}], 30.0, 0.0, "en")
ok("lrc without any time: spread over the song", lnone["lines"][0]["t0"] == 0.0 and lnone["lines"][1]["t1"] == 30.0)
inv("lrc no times", lnone["lines"], 30.0)
Lb = [{"text": "first line sung here", "t": 10.0}, {"text": "", "t": 12.5}, {"text": "after the break", "t": 30.0}]
lb = sa.lines_from_lrc(Lb, 60.0, 0.0, "en")
ok("lrc: blank timed line ends the previous line (interlude)", len(lb["lines"]) == 2 and lb["lines"][0]["t1"] == 12.5, lb["lines"][0])
ok("lrc empty input", sa.lines_from_lrc([], 30.0)["lines"] == [])
lj = sa.lines_from_lrc(LJ, 60.0, 0.0, "ja", Reader())
ok("lrc japanese: words from the tokenizer, est", len(lj["lines"]) == 6 and lj["lines"][1]["words"][0]["w"] == "君" and lj["lines"][1]["words"][0]["est"])
inv("lrc japanese", lj["lines"], 60.0)

# ------------------------------------------------------------------------------------------------------------------
print("[lines from the recognised words (no lyrics)]")
asr_l = (words_at(["I", "walk", "down", "the", "road,"], 2.0) + words_at(["it", "is", "late."], 6.0)
         + words_at(["new", "verse", "starts"], 14.0))
for w in asr_l[5:8]:
    w["p"] = 0.5
la = sa.lines_from_asr(asr_l, 30.0, "en")
ok("asr lines: pause >= 0.8 s splits lines", [ln["text"] for ln in la["lines"]] == ["I walk down the road,", "it is late.", "new verse starts"], [ln["text"] for ln in la["lines"]])
ok("asr lines: pause >= 3 s starts a stanza", [ln["p"] for ln in la["lines"]] == [0, 0, 1], [ln["p"] for ln in la["lines"]])
ok("asr lines: word times are the recognised ones, est False, conf = mean probability",
   la["lines"][0]["words"][1]["s"] == 2.5 and not any(w["est"] for ln in la["lines"] for w in ln["words"]) and la["lines"][1]["conf"] == 0.5 and la["lines"][0]["conf"] == 0.9)
ok("asr lines: edge punctuation stripped from word labels", la["lines"][0]["words"][4]["w"] == "road")
inv("asr lines", la["lines"], 30.0)
ok("asr lines: empty recognition -> no lines, no_vocals", sa.lines_from_asr([], 30.0)["lines"] == [] and "no_vocals" in sa.lines_from_asr([], 30.0)["warnings"])
ok("asr lines: almost no speech -> no_vocals", "no_vocals" in sa.lines_from_asr([{"w": "hm", "s": 1.0, "e": 1.2}], 30.0)["warnings"])
long12 = sa.lines_from_asr(words_at(["w%d" % k for k in range(30)], 0.0, 0.3, 0.25), 30.0, "en")
ok("asr lines: at most 12 words per line", max(len(ln["words"]) for ln in long12["lines"]) <= 12 and len(long12["lines"]) == 3)
inv("asr lines long", long12["lines"], 30.0)
lja = sa.lines_from_asr([{"w": "きみが", "s": 1.0, "e": 1.5}, {"w": "すき。", "s": 1.5, "e": 2.0}, {"w": "ずっと", "s": 4.0, "e": 4.5}], 10.0, "ja")
ok("asr lines japanese: joined without spaces", [ln["text"] for ln in lja["lines"]] == ["きみがすき。", "ずっと"], [ln["text"] for ln in lja["lines"]])
inv("asr lines japanese", lja["lines"], 10.0)
la1 = sa.lines_from_asr([{"word": " Hello", "start": 1.0, "end": 1.4, "probability": 0.8}], 5.0)
ok("faster-whisper field names accepted", la1["lines"] and la1["lines"][0]["words"][0]["w"] == "Hello" and la1["lines"][0]["conf"] == 0.8)

# ------------------------------------------------------------------------------------------------------------------
print("[size, speed, purity]")
big_lyr = [{"text": " ".join("w%d" % ((k * 7 + j) % 400) for j in range(8)), "p": k // 8} for k in range(400)]
big_asr = [{"w": "w%d" % ((k * 3) % 400), "s": round(k * 0.3, 2), "e": round(k * 0.3 + 0.25, 2)} for k in range(800)]
t0 = time.time()
rb = sa.align_lyrics(big_lyr, big_asr, 400.0, "en")
dt = time.time() - t0
ok("400 lines x 8 words vs 800 recognised words finish in < 15 s (%.1f s)" % dt, dt < 15.0)
inv("big english", rb["lines"], 400.0)
jtext = [{"text": "夜の空に歌を歌う君が好きだと言えなくて" * 2} for _ in range(40)]
jasr = [{"w": "ヨルノソラニウタヲ", "s": round(k * 0.7, 2), "e": round(k * 0.7 + 0.6, 2)} for k in range(120)]
t0 = time.time()
rbj = sa.align_lyrics(jtext, jasr, 100.0, "ja", Reader())
dt = time.time() - t0
ok("40 long japanese lines finish in < 15 s (%.1f s)" % dt, dt < 15.0)
inv("big japanese", rbj["lines"], 100.0)
rnd = random.Random(11)
fuzz_ok = True
for case in range(30):
    n_l = rnd.randint(1, 6)
    vocab = ["alpha", "beta", "gamma", "delta", "sun", "moon", "star", "night", "day", "love", "go", "run"]
    lyr = [{"text": " ".join(rnd.choice(vocab) for _ in range(rnd.randint(0, 7))), "p": rnd.randint(0, 2)} for _ in range(n_l)]
    asr = [{"w": rnd.choice(vocab), "s": round(rnd.uniform(0, 30), 2), "e": round(rnd.uniform(0, 31), 2)} for _ in range(rnd.randint(0, 25))]
    dur = rnd.choice([5.0, 20.0, 31.0])
    try:
        res = sa.align_lyrics(lyr, asr, dur, "en")
        fuzz_ok = fuzz_ok and not sa.check_lines(res["lines"], dur)
        res2 = sa.lines_from_lrc([dict(x, t=rnd.choice([None, rnd.uniform(0, 40)])) for x in lyr], dur, rnd.uniform(-3, 3), "en")
        fuzz_ok = fuzz_ok and not sa.check_lines(res2["lines"], dur)
    except Exception as exc:                                # pragma: no cover
        fuzz_ok = False
        print("   fuzz case", case, repr(exc))
ok("30 random cases keep the output invariants (align + lrc)", fuzz_ok)

src_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "song_align.py")
with open(src_path, encoding="utf-8") as f:
    tree = ast.parse(f.read())
mods = set()
for node in ast.walk(tree):
    if isinstance(node, ast.Import):
        mods.update(a.name.split(".")[0] for a in node.names)
    elif isinstance(node, ast.ImportFrom):
        mods.add((node.module or "").split(".")[0])
heavy = {"torch", "faster_whisper", "numpy", "scipy", "pyopenjtalk", "av", "ctranslate2", "onnxruntime", "requests", "fastapi"}
ok("K2-forbidden: song_align imports only the standard library (%s)" % ", ".join(sorted(mods)),
   not (mods & heavy) and mods <= {"difflib", "math", "re", "unicodedata", "bisect"}, mods)
ok("the import check itself notices a heavy import", bool({"numpy"} & heavy))

total_done = True   # reached the end of the file
ok("test ran to the end", total_done)
print("== test_song_align: %d passed, %d failed ==" % (len(PASSED), len(FAILED)))
if FAILED:
    print("FAILED: " + "; ".join(FAILED))
sys.exit(1 if FAILED else 0)
