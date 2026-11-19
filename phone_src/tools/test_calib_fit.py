# -*- coding: utf-8 -*-
"""PA5a tests (docs/v201_design.md 2.4 and 5.5): calib_fit.py and the other calibration tools.

  <repo>\\..\\app\\backend\\.venv\\Scripts\\python.exe -I -X utf8 -m unittest discover -s phone_src\\tools -p test_calib_fit.py

Covers: the map rules of docs 2.1 (map_p / map_final / valid_*), isotonic regression (monotone), ok_prob search, the word agreement
definition, the split by sentence (no leak), the join by clip id (never by position), the gates, final_map, the whole tool on
synthetic runs (success, bytes repeat, shuffled phone clips, empty / broken / one-sided input, a gate failing, --fit-final), a report
without any sentence, calib_record (consent, dry run, nothing written), the audio helpers of calib_make_set, and that the server files
under backend\\ are untouched. The runs are built in memory with the real server `score_en` (this process; no model, no network).

  helper (PA5a-5): python test_calib_fit.py --shuffle-phone <phone.json> <out.json>
      writes a copy of a phone file whose clip CONTENT is moved to other clip ids (the ids stay): a wrongly paired phone file.
Every checker also gets wrong input ("selfcheck" tests).
"""
import contextlib
import copy
import hashlib
import io
import json
import math
import os
import random
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)
ROOT = os.path.dirname(os.path.dirname(HERE))
BACKEND = os.path.join(ROOT, "backend")

import calib_fit as cf   # noqa: E402
import calib_make_set as ms   # noqa: E402
import calib_pc_run as pr   # noqa: E402
import calib_record as rec   # noqa: E402


def backend_state():
    """(sha256 of every file directly in backend\\, the folder names)"""
    h = {}
    for n in sorted(os.listdir(BACKEND)):
        p = os.path.join(BACKEND, n)
        if os.path.isfile(p):
            with open(p, "rb") as f:
                h[n] = hashlib.sha256(f.read()).hexdigest()
    return h, sorted(n for n in os.listdir(BACKEND) if os.path.isdir(os.path.join(BACKEND, n)))


BACKEND_BEFORE = backend_state()
S = None
TMP = None
FIX = {}

VOCAB = ["apple", "banana", "chair", "table", "water", "river", "green", "yellow", "happy", "music", "window", "garden", "summer",
         "winter", "school", "teacher", "friend", "coffee", "dinner", "morning", "evening", "pencil", "office", "market", "doctor",
         "flower", "bridge", "engine", "pocket", "silver", "orange", "purple", "rabbit", "monkey", "basket", "candle", "button",
         "ticket", "castle", "valley"]


def _words(spoken, rng, ps):
    out, t = [], 0.0
    for w, p in zip(spoken, ps):
        out.append({"w": w, "p": round(min(1.0, max(0.0, p)), 4), "start": round(t, 3), "end": round(t + 0.4, 3)})
        t += 0.45
    return out


def make_fixture(n_sent=40, n_user=12, seed=3, wrong_subs=3, phone_fn=lambda p: p ** 1.8, noise=0.02, voices=("v1", "v2")):
    """(pc doc, phone doc) built in memory. PC p of a right word 0.6..1.0; the phone's p is phone_fn(p) + noise (a lower, curved scale)"""
    rng = random.Random(seed)
    pc_clips, ph_clips = [], []

    def add(sid, voice, variant, target_words, group):
        target = " ".join(target_words) + "."
        spoken = list(target_words)
        subs = set()
        if variant.endswith("wrong"):
            subs = set(rng.sample(range(len(spoken)), wrong_subs))
            for i in subs:
                spoken[i] = rng.choice([w for w in VOCAB if w not in target_words])
        ps = [rng.uniform(0.5, 0.95) if i in subs else rng.uniform(0.6, 1.0) for i in range(len(spoken))]
        pcw = _words(spoken, rng, ps)
        text = " ".join(spoken)
        score = S.score_en(target, pcw, text)
        phw = _words(spoken, rng, [phone_fn(p) + rng.gauss(0, noise) for p in ps])
        cid = "%s_%s_%s" % (sid, voice, variant)
        pc_clips.append({"id": cid, "sentence_id": sid, "group": group, "variant": variant, "voice": voice, "target": target,
                         "text": text, "words": pcw, "duration": 2.5, "score": score})
        ph_clips.append({"id": cid, "ok": True, "error": "", "text": text, "duration": 2.5, "ms": 100, "words": phw})

    for k in range(n_sent):
        tw = rng.sample(VOCAB, 5)
        for v in voices:
            add("s%03d" % k, v, "clean", tw, "synth")
            add("s%03d" % k, v, "wrong", tw, "synth")
    for k in range(n_user):
        tw = rng.sample(VOCAB, 5)
        sid = "s%03d" % k if k % 3 == 0 else "u%03d" % k   # some user sentences are also in the synthetic set
        if k % 3 == 0:
            tw = [c for c in pc_clips if c["sentence_id"] == sid][0]["target"].rstrip(".").split()
        add(sid, "user", "user_clean", tw, "user")
        add(sid, "user", "user_wrong", tw, "user")
    pc = {"v": 1, "kind": "pc", "date": "2026-11-19", "clips": pc_clips}
    ph = {"v": 1, "kind": "phone", "model": "ggml-base.en-q5_1.bin", "beam": 1, "clips": ph_clips}
    return pc, ph


def setUpModule():
    global S, TMP
    S = cf.load_server()
    TMP = tempfile.mkdtemp(prefix="hoehwa_calibtest_")
    FIX["good"] = make_fixture()
    FIX["one_word"] = make_fixture(wrong_subs=1, seed=5)


def tearDownModule():
    shutil.rmtree(TMP, ignore_errors=True)


def dump(obj, name):
    p = os.path.join(TMP, name)
    with open(p, "w", encoding="utf-8", newline="\n") as f:
        json.dump(obj, f, ensure_ascii=False)
    return p


def run_cli(pc_doc, ph_doc, tag, extra=()):
    """the whole tool through main(): (exit code, output text, params path, report path)"""
    pcp, php = dump(pc_doc, tag + "_pc.json"), dump(ph_doc, tag + "_phone.json")
    params, report = os.path.join(TMP, tag + "_params.json"), os.path.join(TMP, tag + "_report.json")
    for p in (params, report):
        if os.path.exists(p):
            os.remove(p)
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        code = cf.main(["--pc", pcp, "--phone", php, "--out-params", params, "--report", report] + list(extra))
    return code, buf.getvalue(), params, report


def shuffled_phone(ph_doc):
    """the clip content moved to other ids (half a turn around the sorted ids), the ids stay"""
    d = copy.deepcopy(ph_doc)
    ids = [c["id"] for c in d["clips"]]
    body = [{k: v for k, v in c.items() if k != "id"} for c in d["clips"]]
    k = max(1, len(body) // 2)
    body = body[k:] + body[:k]
    d["clips"] = [dict(b, id=i) for i, b in zip(ids, body)]
    return d


# ================================================================================================ the map rules (docs 2.1)
class MapRules(unittest.TestCase):
    def test_map_p_identity_and_linear(self):
        ident = [[0.0, 0.0], [1.0, 1.0]]
        for p in (0.0, 0.13, 0.5, 0.99, 1.0):
            self.assertAlmostEqual(cf.map_p(p, ident), p)
        m = [[0.0, 0.0], [0.5, 0.2], [1.0, 1.0]]
        self.assertAlmostEqual(cf.map_p(0.25, m), 0.1)         # t = 0.5 inside the first segment
        self.assertAlmostEqual(cf.map_p(0.75, m), 0.6)         # y = 0.2 + 0.8 * 0.5

    def test_map_p_follows_the_sentence_of_the_design(self):
        rng = random.Random(1)
        for _ in range(50):
            xs = sorted(rng.sample([i / 20.0 for i in range(1, 20)], 3))
            ys = sorted(rng.uniform(0, 1) for _ in range(5))
            m = [[0.0, ys[0]], [xs[0], ys[1]], [xs[1], ys[2]], [xs[2], ys[3]], [1.0, ys[4]]]
            p = rng.uniform(0, 1)
            for (x0, y0), (x1, y1) in zip(m, m[1:]):
                if x0 <= p <= x1:
                    t = (p - x0) / (x1 - x0)
                    self.assertAlmostEqual(cf.map_p(p, m), y0 + (y1 - y0) * t, places=9)
                    break

    def test_map_p_end_values_outside_and_nan(self):
        m = [[0.0, 0.1], [1.0, 0.9]]
        self.assertAlmostEqual(cf.map_p(-5.0, m), 0.1)
        self.assertAlmostEqual(cf.map_p(7.0, m), 0.9)
        self.assertAlmostEqual(cf.map_p(float("nan"), m), 0.1)   # NaN is 0
        self.assertAlmostEqual(cf.map_p(None, m), 0.1)
        self.assertAlmostEqual(cf.map_p(float("inf"), m), 0.1)   # not a finite number -> 0

    def test_map_p_invalid_map_leaves_p_alone(self):
        for bad in (None, [], [[0, 0]], [[0, 0.5], [1, 0.2]], "x"):
            self.assertAlmostEqual(cf.map_p(0.37, bad), 0.37)

    def test_valid_p_map_rejects(self):
        bad = {
            "not a list": None, "one point": [[0.0, 0.0]], "33 points": [[i / 32.0, i / 32.0] for i in range(33)],
            "no x 0": [[0.1, 0.0], [1.0, 1.0]], "no x 1": [[0.0, 0.0], [0.9, 1.0]], "x twice": [[0.0, 0.0], [0.5, 0.5], [0.5, 0.6], [1.0, 1.0]],
            "x down": [[0.0, 0.0], [0.6, 0.5], [0.5, 0.6], [1.0, 1.0]], "y down": [[0.0, 0.0], [0.5, 0.6], [0.7, 0.5], [1.0, 1.0]],
            "y above 1": [[0.0, 0.0], [1.0, 1.2]], "y below 0": [[0.0, -0.1], [1.0, 1.0]], "x above 1": [[0.0, 0.0], [1.0, 1.0], [1.5, 1.0]],
            "pair of 3": [[0.0, 0.0, 0.0], [1.0, 1.0, 1.0]], "text": [["a", "b"], ["c", "d"]], "bool": [[True, 0], [1, 1]],
            "nan": [[0.0, 0.0], [1.0, float("nan")]],
        }
        for name, m in bad.items():
            with self.subTest(name):
                self.assertFalse(cf.valid_p_map(m))

    def test_valid_p_map_accepts(self):
        self.assertTrue(cf.valid_p_map([[x, x] for x in cf.P_MAP_X]))
        self.assertTrue(cf.valid_p_map([[0.0, 0.5], [1.0, 0.5]]))           # flat is allowed (non-decreasing)
        self.assertTrue(cf.valid_p_map([[i / 31.0, i / 31.0] for i in range(32)]))   # 32 points

    def test_map_final_rounding_and_clamp(self):
        m = [[0, 0], [50, 70], [100, 100]]
        self.assertEqual(cf.map_final(50, m), 70)
        self.assertEqual(cf.map_final(25, m), 35)
        self.assertEqual(cf.map_final(75, m), 85)
        self.assertEqual(cf.map_final(1, [[0, 0], [100, 50]]), 1)       # 0.5 rounds up (floor(y + 0.5))
        self.assertEqual(cf.map_final(3, [[0, 0], [100, 50]]), 2)       # 1.5 -> 2
        self.assertEqual(cf.map_final(150, m), 100)
        self.assertEqual(cf.map_final(-4, m), 0)
        self.assertEqual(cf.map_final(60, None), 60)                     # not valid: the score stays
        self.assertEqual(cf.map_final(160, "x"), 100)

    def test_valid_final_map(self):
        self.assertTrue(cf.valid_final_map([[0, 0], [100, 100]]))
        self.assertTrue(cf.valid_final_map([[0, 0], [69, 69], [70, 70], [100, 100]]))
        for m in (None, [[0, 0]], [[0, 0], [90, 100]], [[5, 0], [100, 100]], [[0, 0], [50, 80], [60, 70], [100, 100]],
                  [[0, 0], [100, 120]], [[0, 0], [0, 10], [100, 100]]):
            self.assertFalse(cf.valid_final_map(m), m)


# ================================================================================================ fitting
class Fitting(unittest.TestCase):
    def test_isotonic_blocks_monotone_on_noisy_data(self):
        for seed in range(30):
            rng = random.Random(seed)
            pts = [(rng.uniform(0, 1), rng.uniform(0, 1), 1.0) for _ in range(60)]
            blocks = cf.isotonic_blocks(pts)
            ys = [y for _x, y in blocks]
            xs = [x for x, _y in blocks]
            self.assertEqual(ys, sorted(ys), "seed %d: y not non-decreasing" % seed)
            self.assertEqual(xs, sorted(xs))

    def test_isotonic_exact_on_monotone_data_and_pools_a_violation(self):
        pts = [(0.1, 0.1, 1.0), (0.4, 0.5, 1.0), (0.8, 0.9, 1.0)]
        self.assertEqual([(round(x, 6), round(y, 6)) for x, y in cf.isotonic_blocks(pts)], [(0.1, 0.1), (0.4, 0.5), (0.8, 0.9)])
        out = cf.isotonic_blocks([(1.0, 5.0, 1.0), (2.0, 1.0, 1.0)])
        self.assertEqual(len(out), 1)
        self.assertAlmostEqual(out[0][0], 1.5)
        self.assertAlmostEqual(out[0][1], 3.0)

    def test_selfcheck_isotonic_checker_sees_a_decreasing_fit(self):
        self.assertNotEqual([3.0, 1.0], sorted([3.0, 1.0]))   # the check used above (ys == sorted(ys)) fails on a decreasing list

    def test_fit_p_map_recovers_a_known_curve(self):
        rng = random.Random(4)
        pairs = []
        for _ in range(600):
            pc_p = rng.uniform(0.2, 1.0)
            pairs.append((pc_p ** 2, pc_p))   # the phone scale is the square: the map must be the square root
        m = cf.fit_p_map(pairs)
        self.assertTrue(cf.valid_p_map(m))
        self.assertEqual([x for x, _y in m], cf.P_MAP_X)
        for x, y in m:
            if 0.1 <= x <= 0.9:
                self.assertAlmostEqual(y, math.sqrt(x), delta=0.05, msg="x=%s" % x)

    def test_fit_p_map_always_valid_for_random_pairs(self):
        for seed in range(25):
            rng = random.Random(seed)
            pairs = [(rng.uniform(0, 1), rng.uniform(0, 1)) for _ in range(rng.randint(10, 80))]
            self.assertTrue(cf.valid_p_map(cf.fit_p_map(pairs)), "seed %d" % seed)

    def test_fit_p_map_needs_data(self):
        with self.assertRaises(cf.CalibError) as cm:
            cf.fit_p_map([(0.5, 0.5)] * 3)
        self.assertEqual(cm.exception.code, "data")

    def test_fit_ok_prob_finds_the_threshold(self):
        ident = [[0.0, 0.0], [1.0, 1.0]]
        ps = [i / 20.0 for i in range(1, 21)]
        wrows = [([p >= 0.55 for p in ps], list(ps))]
        t = cf.fit_ok_prob(wrows, ident)
        self.assertTrue(0.51 <= t <= 0.55, t)
        self.assertEqual(cf.ok_agreement([(a, p >= t) for a, p in zip(wrows[0][0], ps)]), 1.0)

    def test_fit_ok_prob_tie_goes_to_045_and_missing_words_count_as_not_ok(self):
        ident = [[0.0, 0.0], [1.0, 1.0]]
        self.assertEqual(cf.fit_ok_prob([([True, True], [1.0, 0.99])], ident), 0.45)
        # a word the phone did not match (None) is not ok on the phone side: PC ok=False agrees, PC ok=True does not
        t = cf.fit_ok_prob([([False, False, True], [None, 0.2, 0.9])], ident)
        self.assertTrue(0.21 <= t <= 0.79)
        self.assertEqual(cf.fit_ok_prob([([False, False], [None, None])], ident), 0.45)

    def test_ok_agreement_definition(self):
        self.assertEqual(cf.ok_agreement([(True, True), (True, False), (False, False), (False, True)]), 0.5)
        self.assertEqual(cf.ok_agreement([(True, True)] * 3), 1.0)
        self.assertEqual(cf.ok_agreement([]), 0.0)
        self.assertEqual(cf.ok_agreement([(True, False)] * 4), 0.0)   # selfcheck: a checker that only says 1.0 would fail here

    def test_wilson_and_percentile(self):
        lo, hi = cf.wilson(85, 100)
        self.assertTrue(0.76 < lo < 0.80 and 0.89 < hi < 0.93, (lo, hi))
        self.assertEqual(cf.wilson(0, 0), [0.0, 1.0])
        self.assertEqual(cf.percentile90(list(range(1, 11))), 9)    # rank ceil(0.9 * 10) = 9
        self.assertEqual(cf.percentile90([5]), 5)
        self.assertIsNone(cf.percentile90([]))

    def test_model_id_from_file(self):
        self.assertEqual(cf.model_id_from_file("ggml-base.en-q5_1.bin"), "whisper-base.en-q5_1")
        self.assertEqual(cf.model_id_from_file("C:\\x\\ggml-tiny.en-q5_1.bin"), "whisper-tiny.en-q5_1")
        self.assertEqual(cf.model_id_from_file(""), "")


# ================================================================================================ split, join, files
class SplitAndJoin(unittest.TestCase):
    def rows(self, doc=None):
        pc, ph = doc or FIX["good"]
        pcm = {c["id"]: dict(c, sentence_id=str(c["sentence_id"])) for c in pc["clips"]}
        phm = {c["id"]: c for c in ph["clips"]}
        return cf.join_clips(pcm, phm)

    def test_split_no_sentence_on_both_sides(self):
        rows = self.rows()
        train, held = cf.split_sentences(rows, 7, 0.3)
        a = {r[0]["sentence_id"] for r in train}
        b = {r[0]["sentence_id"] for r in held}
        self.assertTrue(a and b)
        self.assertEqual(a & b, set())
        self.assertEqual(len(train) + len(held), len(rows))

    def test_split_is_by_sentence_across_groups(self):
        rows = self.rows()
        train, held = cf.split_sentences(rows, 7, 0.3)
        for side in (train, held):
            for sid in {r[0]["sentence_id"] for r in side}:
                same = [r for r in rows if r[0]["sentence_id"] == sid]
                self.assertTrue(all(r in side for r in same), "sentence %s is on both sides" % sid)

    def test_split_deterministic_and_seed_dependent(self):
        rows = self.rows()
        a = cf.split_sentences(rows, 7, 0.3)
        b = cf.split_sentences(rows, 7, 0.3)
        c = cf.split_sentences(rows, 8, 0.3)
        ids = lambda x: sorted(r[0]["id"] for r in x[1])
        self.assertEqual(ids(a), ids(b))
        self.assertNotEqual(ids(a), ids(c))

    def test_split_fraction(self):
        rows = self.rows()
        sents = {r[0]["sentence_id"] for r in rows}
        _t, held = cf.split_sentences(rows, 7, 0.3)
        self.assertEqual(len({r[0]["sentence_id"] for r in held}), int(round(len(sents) * 0.3)))

    def test_split_needs_two_sentences(self):
        rows = [r for r in self.rows() if r[0]["sentence_id"] == "s001"]
        with self.assertRaises(cf.CalibError):
            cf.split_sentences(rows, 7, 0.3)

    def test_join_is_by_id_not_by_position(self):
        pc, ph = FIX["good"]
        pcm = {c["id"]: dict(c, sentence_id=str(c["sentence_id"])) for c in pc["clips"]}
        phm = {c["id"]: c for c in reversed(ph["clips"])}   # the file order is reversed; the ids still match
        rows = cf.join_clips(pcm, phm)
        self.assertTrue(all(a["id"] == b["id"] for a, b in rows))
        self.assertEqual(len(rows), len(pc["clips"]))

    def test_join_one_side_only_is_an_error(self):
        pc, ph = FIX["good"]
        pcm = {c["id"]: dict(c) for c in pc["clips"]}
        phm = {c["id"]: c for c in ph["clips"][1:]}
        with self.assertRaises(cf.CalibError) as cm:
            cf.join_clips(pcm, phm)
        self.assertEqual(cm.exception.code, "pairing")

    def test_read_run_rejects_bad_files(self):
        pc, ph = FIX["good"]
        cases = {
            "broken json": "{not json",
            "no clips": json.dumps({"v": 1}),
            "clips not a list": json.dumps({"clips": 3}),
        }
        for name, txt in cases.items():
            p = os.path.join(TMP, "bad_%s.json" % name.replace(" ", "_"))
            with open(p, "w", encoding="utf-8") as f:
                f.write(txt)
            with self.subTest(name), self.assertRaises(cf.CalibError):
                cf.read_run(p, "phone")
        dup = copy.deepcopy(ph)
        dup["clips"].append(copy.deepcopy(dup["clips"][0]))
        badword = copy.deepcopy(ph)
        badword["clips"][0]["words"][0].pop("p")
        for name, doc in (("duplicate id", dup), ("word without p", badword)):
            with self.subTest(name), self.assertRaises(cf.CalibError):
                cf.read_run(dump(doc, "bad2.json"), "phone")
        badunit = copy.deepcopy(pc)
        badunit["clips"][0]["score"]["units"][0].pop("ok")
        with self.assertRaises(cf.CalibError):
            cf.read_run(dump(badunit, "bad3.json"), "pc")

    def test_pair_agreement_high_for_the_same_clips_and_low_for_shuffled(self):
        pc, ph = FIX["good"]
        pcm = {c["id"]: dict(c, sentence_id=str(c["sentence_id"])) for c in pc["clips"]}
        good = cf.join_clips(pcm, {c["id"]: c for c in ph["clips"]})
        bad = cf.join_clips(pcm, {c["id"]: c for c in shuffled_phone(ph)["clips"]})
        a, b = cf.pair_agreement(S, good), cf.pair_agreement(S, bad)
        self.assertGreater(a, 0.9)
        self.assertLess(b, cf.MIN_PAIR_AGREEMENT)
        self.assertEqual(cf.pair_agreement(S, []), 0.0)


# ================================================================================================ gates
class Gates(unittest.TestCase):
    GOOD = {"ok_agree_synth": 0.9, "ok_agree_user": 0.85, "score_mae": 5.0, "score_p90": 12.0, "fluency_mae": 8.0,
            "wrong_lower_pairs": 0.97, "wrong_pass_rate": 0.05, "clean_fail_rate": 0.04}
    BAD = {"ok_agree_synth": 0.84, "ok_agree_user": 0.79, "score_mae": 10.5, "score_p90": 20.5, "fluency_mae": 15.5,
           "wrong_lower_pairs": 0.94, "wrong_pass_rate": 0.11, "clean_fail_rate": 0.11}

    def test_all_good_passes(self):
        r = cf.judge(self.GOOD, {"synth", "user"})
        self.assertEqual([g["result"] for g in r], ["OK"] * 8)

    def test_each_gate_fails_alone(self):
        for name, bad in self.BAD.items():
            m = dict(self.GOOD)
            m[name] = bad
            r = {g["name"]: g["result"] for g in cf.judge(m, {"synth", "user"})}
            self.assertEqual([k for k, v in r.items() if v == "FAIL"], [name])

    def test_the_limits_themselves_pass(self):
        m = {"ok_agree_synth": 0.85, "ok_agree_user": 0.80, "score_mae": 10.0, "score_p90": 20.0, "fluency_mae": 15.0,
             "wrong_lower_pairs": 0.95, "wrong_pass_rate": 0.10, "clean_fail_rate": 0.10}
        self.assertEqual([g["result"] for g in cf.judge(m, {"synth", "user"})], ["OK"] * 8)

    def test_waived_gates_are_not_judged(self):
        m = dict(self.GOOD, score_mae=99.0, score_p90=99.0)
        r = {g["name"]: g["result"] for g in cf.judge(m, {"synth", "user"}, cf.FINAL_MAP_WAIVES)}
        self.assertEqual((r["score_mae"], r["score_p90"]), ("WAIVED", "WAIVED"))
        self.assertEqual(sum(1 for v in r.values() if v == "FAIL"), 0)
        r = {g["name"]: g["result"] for g in cf.judge(m, {"synth", "user"})}
        self.assertEqual((r["score_mae"], r["score_p90"]), ("FAIL", "FAIL"))   # without the waiver the same numbers fail

    def test_missing_group_is_skipped_but_missing_data_in_a_present_group_fails(self):
        m = dict(self.GOOD, ok_agree_user=None)
        r = {g["name"]: g["result"] for g in cf.judge(m, {"synth"})}
        self.assertEqual(r["ok_agree_user"], "SKIP")
        r = {g["name"]: g["result"] for g in cf.judge(m, {"synth", "user"})}
        self.assertEqual(r["ok_agree_user"], "FAIL")
        r = {g["name"]: g["result"] for g in cf.judge(dict(self.GOOD, wrong_lower_pairs=None), {"synth", "user"})}
        self.assertEqual(r["wrong_lower_pairs"], "FAIL")   # not measured is not passed


# ================================================================================================ final_map (the last fallback)
class FinalMap(unittest.TestCase):
    def rows(self, doc):
        pc, ph = doc
        pcm = {c["id"]: dict(c, sentence_id=str(c["sentence_id"])) for c in pc["clips"]}
        return cf.join_clips(pcm, {c["id"]: c for c in ph["clips"]})

    def test_fit_final_map_separates_clean_from_wrong_and_is_monotone(self):
        rows = self.rows(FIX["one_word"])
        pairs = cf.matched_pairs(S, rows)
        p_map = cf.fit_p_map(pairs)
        ok_prob = cf.fit_ok_prob(cf.word_rows(S, rows), p_map)
        base = cf.evaluate(S, rows, p_map, ok_prob, None)
        self.assertGreater(base["wrong_pass_rate"], 0.5, "the fixture must need the fallback")
        m = cf.fit_final_map(S, rows, p_map, ok_prob)
        self.assertIsNotNone(m)
        self.assertTrue(cf.valid_final_map(m))
        ys = [y for _x, y in m]
        self.assertEqual(ys, sorted(ys))
        after = cf.evaluate(S, rows, p_map, ok_prob, m)
        self.assertLessEqual(after["wrong_pass_rate"], 0.10)
        self.assertLessEqual(after["clean_fail_rate"], 0.10)

    def test_fit_final_map_none_when_clean_and_wrong_cannot_be_separated(self):
        pc, ph = copy.deepcopy(FIX["one_word"])
        pcb = {c["id"]: c for c in pc["clips"]}
        phb = {c["id"]: c for c in ph["clips"]}
        # every "wrong" clip becomes a copy of its clean twin (same words, same score): no step can split them
        for cid in list(pcb):
            if pcb[cid]["variant"].endswith("wrong"):
                twin = cid[:-5] + "clean"
                pcb[cid] = dict(copy.deepcopy(pcb[twin]), id=cid, variant=pcb[cid]["variant"])
                phb[cid] = dict(copy.deepcopy(phb[twin]), id=cid)
        pc["clips"], ph["clips"] = list(pcb.values()), list(phb.values())
        rows = self.rows((pc, ph))
        self.assertIsNone(cf.fit_final_map(S, rows, [[0.0, 0.0], [1.0, 1.0]], 0.45))


# ================================================================================================ the whole tool
class WholeTool(unittest.TestCase):
    def test_success_writes_valid_params_and_a_numbers_only_report(self):
        code, out, params, report = run_cli(*FIX["good"], "good")
        self.assertEqual(code, 0, out)
        self.assertIn("CALIB_OK", out)
        p = json.load(open(params, encoding="utf-8"))
        self.assertEqual(p["v"], 1)
        self.assertEqual(p["model_id"], "whisper-base.en-q5_1")
        self.assertIs(p["calibrated"], True)
        self.assertIn(p["beam"], (1, 2, 3))
        self.assertTrue(0.2 < p["ok_prob"] < 0.8)
        self.assertTrue(cf.valid_p_map(p["p_map"]))
        self.assertTrue(cf.valid_final_map(p["final_map"]))
        self.assertEqual(p["date"], "2026-11-19")
        for k in ("synth_clips", "user_clips", "ok_agree_synth", "ok_agree_user", "score_mae", "score_p90", "fluency_mae",
                  "wrong_lower_pairs", "wrong_pass_rate", "clean_fail_rate", "fallback"):
            self.assertIn(k, p["report"])
        self.assertEqual(p["report"]["fallback"], "none")
        r = json.load(open(report, encoding="utf-8"))
        self.assertEqual(r["status"], "ok")
        self.assertEqual(r["failed"], [])
        self.assertEqual(r["clips"]["total"], len(FIX["good"][0]["clips"]))
        self.assertTrue(all(g["result"] in ("OK", "SKIP") for g in r["gates"]))

    def test_same_input_same_seed_same_bytes(self):
        _c, _o, p1, _r = run_cli(*FIX["good"], "rep1")
        _c, _o, p2, _r = run_cli(*FIX["good"], "rep2")
        self.assertEqual(open(p1, "rb").read(), open(p2, "rb").read())

    def test_another_seed_may_split_differently_but_still_runs(self):
        code, out, params, _r = run_cli(*FIX["good"], "seed9", ("--seed", "9"))
        self.assertEqual(code, 0, out)
        self.assertTrue(os.path.exists(params))

    def test_phone_clips_in_another_order_give_the_same_result(self):
        pc, ph = FIX["good"]
        rev = copy.deepcopy(ph)
        rev["clips"] = list(reversed(rev["clips"]))
        _c, _o, p1, _r = run_cli(pc, ph, "ord1")
        c2, o2, p2, _r = run_cli(pc, rev, "ord2")
        self.assertEqual(c2, 0, o2)
        self.assertEqual(open(p1, "rb").read(), open(p2, "rb").read())   # joined by id: the file order does not matter

    def test_shuffled_phone_clips_fail_with_agreement_and_no_params(self):
        pc, ph = FIX["good"]
        code, out, params, report = run_cli(pc, shuffled_phone(ph), "shuf")
        self.assertEqual(code, 1)
        self.assertIn("CALIB_FAIL agreement", out)
        self.assertFalse(os.path.exists(params))

    def test_empty_and_broken_and_one_sided_input_exit_1(self):
        pc, ph = FIX["good"]
        e1 = dict(pc, clips=[])
        e2 = dict(ph, clips=[])
        for name, (a, b, word) in {
            "both empty": (e1, e2, "CALIB_FAIL data"),
            "phone empty": (pc, e2, "CALIB_FAIL pairing"),
            "pc empty": (e1, ph, "CALIB_FAIL pairing"),
            "empty object": ({}, {}, "CALIB_FAIL input"),
            "one clip only on the pc side": (pc, dict(ph, clips=ph["clips"][1:]), "CALIB_FAIL pairing"),
            "one clip only on the phone side": (dict(pc, clips=pc["clips"][1:]), ph, "CALIB_FAIL pairing"),
        }.items():
            with self.subTest(name):
                code, out, params, report = run_cli(a, b, "emp")
                self.assertEqual(code, 1, out)
                self.assertIn(word, out)
                self.assertFalse(os.path.exists(params))

    def test_broken_json_file_exits_1(self):
        pcp = os.path.join(TMP, "brk_pc.json")
        with open(pcp, "w", encoding="utf-8") as f:
            f.write("{\"clips\": [")
        php = dump(FIX["good"][1], "brk_phone.json")
        params = os.path.join(TMP, "brk_params.json")
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            code = cf.main(["--pc", pcp, "--phone", php, "--out-params", params, "--report", os.path.join(TMP, "brk_rep.json")])
        self.assertEqual(code, 1)
        self.assertIn("CALIB_FAIL input", buf.getvalue())
        self.assertFalse(os.path.exists(params))

    def test_a_gate_below_its_limit_fails_and_writes_no_params(self):
        pc, ph = FIX["good"]
        bad = copy.deepcopy(ph)
        for c in bad["clips"]:   # the phone misses two of the five words in every clip (the clips still pair: 3 of 5 words agree)
            c["words"] = [w for i, w in enumerate(c["words"]) if i not in (1, 3)]
        code, out, params, report = run_cli(pc, bad, "gatefail")
        self.assertEqual(code, 1, out)
        self.assertIn("CALIB_FAIL ", out)
        self.assertNotIn("CALIB_FAIL agreement", out)
        self.assertFalse(os.path.exists(params))
        r = json.load(open(report, encoding="utf-8"))
        self.assertEqual(r["status"], "fail")
        self.assertTrue(r["failed"])

    def test_fit_final_rescues_a_one_word_error_set(self):
        pc, ph = FIX["one_word"]
        code, out, params, report = run_cli(pc, ph, "onew")
        self.assertEqual(code, 1, out)
        self.assertIn("wrong_pass_rate", out)
        code, out, params, report = run_cli(pc, ph, "onew_ff", ("--fit-final",))
        self.assertEqual(code, 0, out)
        p = json.load(open(params, encoding="utf-8"))
        self.assertNotEqual(p["final_map"], [[0, 0], [100, 100]])
        self.assertEqual(p["report"]["fallback"], "final_map")
        self.assertTrue(cf.valid_final_map(p["final_map"]))
        r = {g["name"]: g["result"] for g in json.load(open(report, encoding="utf-8"))["gates"]}
        self.assertEqual((r["score_mae"], r["score_p90"]), ("WAIVED", "WAIVED"))   # moved away from the PC's score on purpose
        self.assertEqual(r["wrong_pass_rate"], "OK")

    def test_beam_other_than_one_is_recorded_as_the_beam_fallback(self):
        pc, ph = FIX["good"]
        ph2 = dict(ph, beam=2)
        code, out, params, _r = run_cli(pc, ph2, "beam2")
        self.assertEqual(code, 0, out)
        p = json.load(open(params, encoding="utf-8"))
        self.assertEqual((p["beam"], p["report"]["fallback"]), (2, "beam"))
        code, out, _p, _r = run_cli(pc, dict(ph, beam=7), "beam7")
        self.assertEqual(code, 1)

    def test_report_holds_no_sentence_and_no_word_of_one(self):
        _c, _o, params, report = run_cli(*FIX["good"], "priv")
        text = open(report, encoding="utf-8").read() + open(params, encoding="utf-8").read()
        hits = [w for w in VOCAB if re.search(r"\b%s\b" % w, text)]
        self.assertEqual(hits, [])
        self.assertFalse(re.search(r"[A-Za-z]{3,} [A-Za-z]{3,} [A-Za-z]{3,}", text))
        # selfcheck: the same scan finds a sentence when there is one
        self.assertTrue(re.search(r"[A-Za-z]{3,} [A-Za-z]{3,} [A-Za-z]{3,}", "the quick brown fox"))

    def test_ok_prob_constant_of_the_server_is_put_back(self):
        before = S.OK_PROB
        run_cli(*FIX["good"], "okp")
        self.assertEqual(S.OK_PROB, before)
        with cf.ok_prob_as(S, 0.3):
            self.assertEqual(S.OK_PROB, 0.3)
        self.assertEqual(S.OK_PROB, before)

    def test_usage_errors_exit_2(self):
        for argv in ([], ["--pc", "a.json"], ["--pc", "a", "--phone", "b", "--out-params", "c", "--report", "d", "--holdout", "1.5"]):
            buf = io.StringIO()
            try:
                with contextlib.redirect_stdout(buf), contextlib.redirect_stderr(io.StringIO()):
                    code = cf.main(argv)
            except SystemExit as e:
                code = e.code
            self.assertEqual(code, 2, argv)

    def test_command_line_exit_code_and_missing_output_argument(self):
        r = subprocess.run([sys.executable, "-I", "-X", "utf8", os.path.join(HERE, "calib_fit.py")], capture_output=True)
        self.assertEqual(r.returncode, 2)
        r = subprocess.run([sys.executable, "-I", "-X", "utf8", os.path.join(HERE, "calib_fit.py"), "--pc", os.path.join(TMP, "nope.json"),
                            "--phone", os.path.join(TMP, "nope2.json"), "--out-params", os.path.join(TMP, "x_params.json"),
                            "--report", os.path.join(TMP, "x_rep.json")], capture_output=True)
        self.assertEqual(r.returncode, 1)
        self.assertIn(b"CALIB_FAIL input", r.stdout)


# ================================================================================================ calib_record, calib_make_set, calib_pc_run
class OtherTools(unittest.TestCase):
    def test_pool_and_choose_wrong_are_deterministic_and_valid(self):
        pool = ms.load_pool()
        self.assertGreaterEqual(len(pool), 200)
        for sid, text in pool[:50]:
            self.assertTrue(3 <= len(text.split()) <= 10)
        a = ms.pick_sentences(pool, 20, 7)
        self.assertEqual(a, ms.pick_sentences(pool, 20, 7))
        self.assertNotEqual(a, ms.pick_sentences(pool, 20, 8))
        vocab = ms.vocabulary(pool)
        for sid, text in a:
            wrong, spoken = ms.choose_wrong(text, random.Random(5), vocab)
            toks, stoks = text.split(), spoken.split()
            self.assertEqual(len(toks), len(stoks))
            diff = [i for i in range(len(toks)) if toks[i] != stoks[i]]
            self.assertEqual(diff, [wrong["index"]])
            self.assertNotEqual(wrong["said"], re.sub(r"[^a-z']", "", toks[wrong["index"]].lower()))
        w1 = ms.choose_wrong(a[0][1], random.Random(5), vocab)
        self.assertEqual(w1, ms.choose_wrong(a[0][1], random.Random(5), vocab))

    def test_audio_helpers(self):
        import numpy as np
        import soundfile as sf
        x = np.sin(np.linspace(0, 400 * math.pi, 16000)).astype(np.float32) * 0.5
        for snr in (20.0, 10.0):
            y = ms.add_noise(x, snr, 123)
            noise = y - x
            got = 10 * math.log10(float(np.mean(x ** 2)) / float(np.mean(noise ** 2)))
            self.assertAlmostEqual(got, snr, delta=0.3)
            self.assertTrue(np.array_equal(y, ms.add_noise(x, snr, 123)))
        self.assertEqual(len(ms.band_limit_8k(x)), len(x))
        path = os.path.join(TMP, "a.wav")
        secs = ms.write_wav16(path, x)
        self.assertAlmostEqual(secs, 1.0)
        data, sr = sf.read(path, dtype="int16")
        self.assertEqual((sr, data.ndim), (16000, 1))
        self.assertEqual(len(ms.add_noise(np.zeros(0, dtype=np.float32), 10.0, 1)), 0)

    def test_pc_run_manifest_checks(self):
        d = os.path.join(TMP, "mset")
        os.makedirs(os.path.join(d, "clips"), exist_ok=True)
        with open(os.path.join(d, "manifest.json"), "w", encoding="utf-8") as f:
            f.write("{bad")
        with self.assertRaises(pr.PcRunError):
            pr.read_manifest(d)
        ok = {"clips": [{"clip": "a", "file": "clips/a.wav", "target": "x y z", "sha256": "00", "sentence_id": "1"}]}
        with open(os.path.join(d, "manifest.json"), "w", encoding="utf-8") as f:
            json.dump(ok, f)
        self.assertEqual(len(pr.read_manifest(d)["clips"]), 1)
        ok["clips"].append(dict(ok["clips"][0]))   # the same clip id twice
        with open(os.path.join(d, "manifest.json"), "w", encoding="utf-8") as f:
            json.dump(ok, f)
        with self.assertRaises(pr.PcRunError):
            pr.read_manifest(d)
        # a clip file that does not match its sha256 stops the run before the model loads
        ok["clips"] = ok["clips"][:1]
        with open(os.path.join(d, "clips", "a.wav"), "wb") as f:
            f.write(b"RIFFxxxx")
        with open(os.path.join(d, "manifest.json"), "w", encoding="utf-8") as f:
            json.dump(ok, f)
        with self.assertRaises(pr.PcRunError) as cm:
            pr.run(d, os.path.join(TMP, "never.json"), out=lambda *_: None)
        self.assertEqual(str(cm.exception), "sha256")
        self.assertFalse(os.path.exists(os.path.join(TMP, "never.json")))

    def test_record_dry_run_shows_consent_and_30_sentences_and_writes_nothing(self):
        lines = []
        out_dir = os.path.join(TMP, "rec_dry_unit")
        code = rec.run(out_dir, True, 11, input_fn=lambda *_: self.fail("a dry run must not ask anything"),
                       recorder=lambda *_: self.fail("a dry run must not record"), out=lines.append)
        self.assertEqual(code, 0)
        text = "\n".join(lines)
        self.assertIn(rec.CONSENT_TEXT, text)
        self.assertEqual(len(re.findall(r"^문장 \d\d/30$", text, re.M)), 30)
        self.assertFalse(os.path.exists(out_dir))
        for frag in ("영어 문장 30개를", "한 번은 바르게", "화면이 알려 주는 낱말 하나를 바꿔서 읽어요(약 8분)",
                     "이 PC 의 임시 폴더에만 저장되고 저장소·인터넷으로 나가지 않아요", "보정이 끝나면 지워요(원하면 보관)", "시작할까요? (y/n)"):
            self.assertIn(frag, rec.CONSENT_TEXT)

    def test_record_needs_y_and_keeps_only_what_the_user_agreed_to(self):
        import numpy as np
        out_dir = os.path.join(TMP, "rec_no")
        lines = []
        code = rec.run(out_dir, False, 11, input_fn=lambda *_: "n", recorder=lambda *_: self.fail("no recording without consent"),
                       out=lines.append)
        self.assertEqual(code, 1)
        self.assertFalse(os.path.exists(out_dir))
        for answer in ("", "yes", "no", "ja"):
            d = os.path.join(TMP, "rec_no_%s" % (answer or "empty"))
            self.assertEqual(rec.run(d, False, 11, input_fn=lambda *_, a=answer: a, recorder=lambda *_: self.fail("x"), out=lambda *_: None), 1)
            self.assertFalse(os.path.exists(d))
        # consent given, 'q' after 3 clips: the three clips are kept with a manifest that records the consent
        out_dir = os.path.join(TMP, "rec_yes")
        answers = iter(["y"] + ["", ""] * 3 + ["q"])   # consent, three clips (start + next each), then q at the fourth
        samples = (np.sin(np.linspace(0, 200 * math.pi, 16000 * 6)) * 12000).astype(np.int16)
        code = rec.run(out_dir, False, 11, input_fn=lambda *_: next(answers), recorder=lambda *_: samples, out=lambda *_: None)
        self.assertEqual(code, 0)
        m = json.load(open(os.path.join(out_dir, "manifest.json"), encoding="utf-8"))
        self.assertEqual(m["kind"], "user")
        self.assertIs(m["consent"]["given"], True)
        self.assertEqual(m["consent"]["text_sha256"], hashlib.sha256(rec.CONSENT_TEXT.encode("utf-8")).hexdigest())
        self.assertEqual(len(m["clips"]), 3)
        for c in m["clips"]:
            self.assertEqual(c["sha256"], rec.sha256_file(os.path.join(out_dir, c["file"])))
            self.assertEqual(c["voice"], "user")
        self.assertEqual([c["variant"] for c in m["clips"][:2]], ["user_clean", "user_wrong"])
        self.assertIsNone(m["clips"][0]["wrong"])
        self.assertIsNotNone(m["clips"][1]["wrong"])
        # a second session into the same (not empty) folder is refused
        self.assertEqual(rec.run(out_dir, False, 11, input_fn=lambda *_: "y", recorder=lambda *_: samples, out=lambda *_: None), 1)

    def test_record_redo_replaces_the_take(self):
        import numpy as np
        out_dir = os.path.join(TMP, "rec_redo")
        answers = iter(["y", "", "r", "", "", "q"])   # start, then redo once, start again, next, q at the 2nd clip
        takes = iter([np.zeros(16000, dtype=np.int16) + 5, (np.ones(32000) * 9000).astype(np.int16)])
        code = rec.run(out_dir, False, 11, input_fn=lambda *_: next(answers), recorder=lambda *_: next(takes), out=lambda *_: None)
        self.assertEqual(code, 0)
        m = json.load(open(os.path.join(out_dir, "manifest.json"), encoding="utf-8"))
        self.assertEqual(len(m["clips"]), 1)
        self.assertAlmostEqual(m["clips"][0]["seconds"], 2.0)   # the second take, not the first

    def test_record_source_has_no_log_file_and_requires_out(self):
        src = open(os.path.join(HERE, "calib_record.py"), encoding="utf-8").read()
        self.assertEqual(len(re.findall(r"logging|\.log", src)), 0)
        for tool in ("calib_record.py", "calib_make_set.py", "calib_pc_run.py"):
            r = subprocess.run([sys.executable, "-I", "-X", "utf8", os.path.join(HERE, tool)], capture_output=True)
            self.assertEqual(r.returncode, 2, tool)
        # selfcheck: the scan for log files sees one when it is there
        self.assertEqual(len(re.findall(r"logging|\.log", "import logging")), 1)

    def test_backend_is_untouched(self):
        self.assertEqual(backend_state(), BACKEND_BEFORE)


def _shuffle_cli(argv):
    with open(argv[0], "r", encoding="utf-8") as f:
        doc = json.load(f)
    out = shuffled_phone(doc)
    with open(argv[1], "w", encoding="utf-8", newline="\n") as f:
        json.dump(out, f, ensure_ascii=False)
    print("SHUFFLED clips=%d" % len(out["clips"]))


if __name__ == "__main__":
    if len(sys.argv) >= 4 and sys.argv[1] == "--shuffle-phone":
        _shuffle_cli(sys.argv[2:4])
        sys.exit(0)
    unittest.main()
