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
import datetime
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
from unittest import mock

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
            "wrong_lower_pairs": 0.97, "wrong_pass_gap": 0.05, "clean_fail_rate": 0.04}
    BAD = {"ok_agree_synth": 0.84, "ok_agree_user": 0.79, "score_mae": 10.5, "score_p90": 20.5, "fluency_mae": 15.5,
           "wrong_lower_pairs": 0.94, "wrong_pass_gap": 0.11, "clean_fail_rate": 0.11}

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
             "wrong_lower_pairs": 0.95, "wrong_pass_gap": 0.10, "clean_fail_rate": 0.10}
        self.assertEqual([g["result"] for g in cf.judge(m, {"synth", "user"})], ["OK"] * 8)

    def test_wrong_pass_gap_boundary_d4(self):
        # D-4: |phone wrong-70+ share - PC share| <= 0.10 : a gap of 0.10 passes, 0.11 fails (and nothing else changes)
        for gap, want in ((0.10, "OK"), (0.11, "FAIL"), (0.0, "OK"), (0.101, "FAIL")):
            r = {g["name"]: g["result"] for g in cf.judge(dict(self.GOOD, wrong_pass_gap=gap), {"synth", "user"})}
            self.assertEqual(r["wrong_pass_gap"], want, gap)
            self.assertEqual([k for k, v in r.items() if v == "FAIL"], [] if want == "OK" else ["wrong_pass_gap"])
        self.assertNotIn("wrong_pass_rate", [g[0] for g in cf.GATES])   # the old "<= 0.10 on the phone alone" gate is gone
        self.assertEqual([g for g in cf.GATES if g[0] == "wrong_pass_gap"], [("wrong_pass_gap", "<=", 0.10, None)])

    def test_wrong_pass_gap_is_judged_with_integers_not_a_rounded_share(self):
        # D-4 exactly: 10 * |phone 70+ count - PC 70+ count| <= wrong clips. A 9-digit rounding of the share would pass the 2nd case.
        def verdict(phone, pc, n):
            gap = round(abs(float(phone) / n - float(pc) / n), 9)   # what evaluate() reports
            m = dict(self.GOOD, wrong_clips=n, wrong_pass_rate=phone / float(n), wrong_pass_rate_pc=pc / float(n), wrong_pass_gap=gap)
            return {g["name"]: g["result"] for g in cf.judge(m, {"synth", "user"})}["wrong_pass_gap"]
        self.assertEqual(verdict(60, 50, 100), "OK")                       # exactly 0.10
        self.assertEqual(verdict(50, 60, 100), "OK")                       # and the other way round
        self.assertEqual(verdict(61, 50, 100), "FAIL")
        self.assertEqual(verdict(1, 0, 10), "OK")
        self.assertEqual(verdict(1, 0, 9), "FAIL")
        self.assertEqual(verdict(130000000, 100000000, 300000000), "OK")   # exactly 0.10
        self.assertEqual(verdict(130000001, 100000000, 300000009), "FAIL")  # 0.1000000003: rounds to 0.1 at 9 digits, still over the limit
        self.assertEqual(verdict(100000000, 130000001, 300000009), "FAIL")
        self.assertEqual(round(30000001 / 300000009.0, 9), 0.1)             # the premise: the rounded share cannot tell
        # without the counts (a bare metrics dict) the number itself is compared as before
        self.assertEqual({g["name"]: g["result"] for g in cf.judge(dict(self.GOOD, wrong_pass_gap=0.10), {"synth", "user"})}["wrong_pass_gap"], "OK")

    def test_evaluate_reports_both_shares_and_their_gap(self):
        pc, ph = FIX["one_word"]
        pcm = {c["id"]: dict(c, sentence_id=str(c["sentence_id"])) for c in pc["clips"]}
        rows = cf.join_clips(pcm, {c["id"]: c for c in ph["clips"]})
        p_map = cf.fit_p_map(cf.matched_pairs(S, rows))
        m = cf.evaluate(S, rows, p_map, cf.fit_ok_prob(cf.word_rows(S, rows), p_map), None)
        want_pc = sum(1 for a, _b in rows if a["variant"] in cf.WRONG_VARIANTS and a["score"]["score"] >= 70) / float(m["wrong_clips"])
        self.assertAlmostEqual(m["wrong_pass_rate_pc"], want_pc)
        self.assertAlmostEqual(m["wrong_pass_gap"], abs(m["wrong_pass_rate"] - m["wrong_pass_rate_pc"]))
        self.assertGreater(m["wrong_pass_rate_pc"], 0.5)   # the fixture: the PC itself passes most one-word-wrong clips

    def test_no_gate_can_be_waived(self):
        import inspect
        self.assertEqual(list(inspect.signature(cf.judge).parameters), ["metrics", "groups_present"])   # D-2: no waiver argument
        self.assertFalse(hasattr(cf, "FINAL_MAP_WAIVES"))
        m = dict(self.GOOD, score_mae=99.0, score_p90=99.0)
        r = {g["name"]: g["result"] for g in cf.judge(m, {"synth", "user"})}
        self.assertEqual((r["score_mae"], r["score_p90"]), ("FAIL", "FAIL"))
        self.assertNotIn("WAIVED", open(os.path.join(HERE, "calib_fit.py"), encoding="utf-8").read().split("def judge")[1].split("def model_id")[0])

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

    def test_report_has_the_per_group_numbers_and_the_wrong_pass_gap(self):
        _c, _o, params, report = run_cli(*FIX["good"], "bygroup")
        r = json.load(open(report, encoding="utf-8"))
        for g in ("synth", "user"):
            for k in ("clips", "ok_agree", "score_mae", "wrong_pass_rate", "wrong_pass_rate_pc", "wrong_pass_gap", "clean_fail_rate"):
                self.assertIn(k, r["holdout_by_group"][g])
        hm = r["holdout_metrics"]
        self.assertAlmostEqual(hm["wrong_pass_gap"], abs(hm["wrong_pass_rate"] - hm["wrong_pass_rate_pc"]), places=3)
        self.assertEqual(r["holdout_by_group"]["synth"]["clips"] + r["holdout_by_group"]["user"]["clips"], r["clips"]["holdout"])

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

    def test_fit_final_is_judged_like_everything_else(self):
        # D-4: the default fit follows the PC (gap gate OK); --fit-final crushes the phone's wrong-70+ share, so the same gap gate fails it
        pc, ph = FIX["one_word"]
        code, out, params, report = run_cli(pc, ph, "onew")
        self.assertEqual(code, 0, out)
        self.assertNotIn("wrong_pass_rate", out)
        r = json.load(open(report, encoding="utf-8"))
        self.assertEqual({g["name"]: g["result"] for g in r["gates"]}["wrong_pass_gap"], "OK")
        self.assertIn("wrong_pass_rate_pc", r["holdout_metrics"])
        code, out, params, report = run_cli(pc, ph, "onew_ff", ("--fit-final",))
        r = json.load(open(report, encoding="utf-8"))
        self.assertNotIn("WAIVED", open(report, encoding="utf-8").read())
        self.assertEqual(code, 1, out)
        self.assertIn("wrong_pass_gap", out)
        self.assertEqual({g["name"]: g["result"] for g in r["gates"]}["wrong_pass_gap"], "FAIL")
        self.assertIsNotNone(r["fit"]["final_map"])
        self.assertTrue(cf.valid_final_map(r["fit"]["final_map"]))
        self.assertFalse(os.path.exists(params))   # a gate under its limit: CALIB_FAIL and no params file (nothing is excused)

    def test_fit_final_with_score_distance_over_the_limit_fails(self):
        # the map must not excuse a score distance: a copy of the data whose PC scores are 15 points higher than the phone's
        pc, ph = copy.deepcopy(FIX["good"])
        for c in pc["clips"]:
            c["score"]["score"] = min(100, c["score"]["score"] + 15) if c["score"]["score"] < 80 else c["score"]["score"] - 15
        code, out, params, report = run_cli(pc, ph, "dist_ff", ("--fit-final",))
        self.assertEqual(code, 1, out)
        self.assertIn("score_mae", out)
        self.assertFalse(os.path.exists(params))
        self.assertNotIn("WAIVED", out)

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
        for answer in ("", "yes", "no", "ja", "Y", "YES", "Yes", " Y ", "y es", "yy", "\u3161"):
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

    def test_consent_is_exactly_a_lower_case_y(self):
        import numpy as np
        calls = []
        for answer in ("Y", " Y", "yes", "", "n", "YES", "yy"):
            calls.clear()
            d = os.path.join(TMP, "cons_%d" % abs(hash(answer)))
            code = rec.run(d, False, 11, input_fn=lambda *_, a=answer: a, recorder=lambda *_: calls.append(1), out=lambda *_: None)
            self.assertEqual((code, len(calls)), (1, 0), repr(answer))
            self.assertFalse(os.path.exists(d))
        samples = np.zeros(16000, dtype=np.int16) + 800
        for answer in ("y", " y ", "y\t"):   # spaces around the letter are ignored, the letter itself is not case folded
            answers = iter([answer, "q"])
            d = os.path.join(TMP, "cons_ok_%d" % abs(hash(answer)))
            self.assertEqual(rec.run(d, False, 11, input_fn=lambda *_: next(answers), recorder=lambda *_: samples, out=lambda *_: None), 0)

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


# ================================================================================================ round 2 (review PA5a_review.md)
GODOT = r"C:\Users\rtyu6\Desktop\Godot_v4.6.3-stable_win64.exe\Godot_v4.6.3-stable_win64_console.exe"


def make_junction(link, target):
    r = subprocess.run(["cmd", "/c", "mklink", "/J", link, target], capture_output=True)
    if r.returncode != 0:
        raise unittest.SkipTest("cannot make a junction here")


def remove_junction(link):
    """removes only the link (cmd rmdir), never what it points at"""
    if os.path.lexists(link):
        subprocess.run(["cmd", "/c", "rmdir", link], capture_output=True)


def short_name(path):
    from ctypes import WinDLL, create_unicode_buffer
    buf = create_unicode_buffer(32768)
    n = WinDLL("kernel32", use_last_error=True).GetShortPathNameW(path, buf, len(buf))
    return buf.value if n else None


class FakeRepo:
    """a disposable stand-in for the repository inside TMP: the forbidden roots are pointed at it, so a test (also a test run with a broken
    guard) can really write there without ever touching a real repository, worktree or backend"""

    def __init__(self, name="fake_repo"):
        self.root = os.path.join(TMP, name)
        for sub in ("backend", "phone_src", "other"):
            os.makedirs(os.path.join(self.root, sub), exist_ok=True)
        self.backend = os.path.join(self.root, "backend")
        self.patches = [mock.patch.object(cf, "FORBIDDEN_ROOTS", (self.root,)), mock.patch.object(cf, "ROOT", self.root),
                        mock.patch.object(cf, "BACKEND", self.backend)]

    def __enter__(self):
        for x in self.patches:
            x.start()
        return self

    def __exit__(self, *a):
        for x in reversed(self.patches):
            x.stop()

    def files(self):
        return [os.path.join(d, f) for d, _s, fs in os.walk(self.root) for f in fs]


def tool_calls(q):
    """(label, callable) for every tool, all writing to / below q"""
    return (
        ("make_set", lambda: ms.main(["--out", q, "--n-sentences", "1", "--voices", "1"])),
        ("record dry", lambda: rec.main(["--out", q, "--dry-run"])),
        ("record", lambda: rec.main(["--out", q])),
        ("pc_run", lambda: pr.main(["--set", TMP, "--out", q + ".json"])),
        ("fit params", lambda: cf.main(["--pc", "a", "--phone", "b", "--out-params", q + ".json", "--report", os.path.join(TMP, "r.json")])),
        ("fit report", lambda: cf.main(["--pc", "a", "--phone", "b", "--out-params", os.path.join(TMP, "p.json"), "--report", q + ".json"])),
    )


class OutBoundary(unittest.TestCase):
    """every tool refuses an output place inside a repository, a worktree or backend, however it is spelled: exit 2 and nothing written.
    Tests that write use a FakeRepo in the scratch folder; nothing here can write into a real repository."""

    def test_the_checker_refuses_real_repos_and_allows_scratch(self):   # only asks, never writes
        for pth in (os.path.join(ROOT, "backend", "zz"), os.path.join(ROOT, "phone_src", "zz"), os.path.join(ROOT, "zz"),
                    r"D:\Ai\언어\app\zz", r"D:\Ai\언어\app_wt\zz", r"D:\Ai\언어\app_wt\v201_other\zz",
                    os.path.join(ROOT, "docs", "..", "backend", "zz"), ROOT, BACKEND, r"d:\ai\언어\APP\x",
                    "\\\\?\\" + os.path.join(ROOT, "backend", "zz"), "\\\\.\\" + os.path.join(ROOT, "backend", "zz")):
            self.assertTrue(cf.out_path_refused(pth), pth)
        for pth in (os.path.join(TMP, "x"), os.path.join(TMP, "a", "..", "b"), r"C:\Users\someone\scratch\x"):
            self.assertFalse(cf.out_path_refused(pth), pth)
        with self.assertRaises(cf.OutPathRefused):
            cf.require_out_paths(os.path.join(TMP, "ok"), os.path.join(ROOT, "backend", "x"))

    def test_resolve_path_spellings(self):
        d = os.path.join(TMP, "resolve_dir")
        os.makedirs(d, exist_ok=True)
        want = cf.resolve_path(d)
        self.assertEqual(cf.resolve_path("\\\\?\\" + d), want)
        self.assertEqual(cf.resolve_path("\\\\.\\" + d), want)
        self.assertEqual(cf.resolve_path(d.upper()), want)
        self.assertEqual(cf.resolve_path(os.path.join(d, "a", "..")), want)
        self.assertEqual(cf.resolve_path(os.path.join(d, "not", "yet", "there")), os.path.join(want, "not", "yet", "there"))
        self.assertEqual(cf._strip_ext_prefix("\\\\?\\UNC\\srv\\share\\x"), "\\\\srv\\share\\x")
        self.assertEqual(cf._strip_ext_prefix("\\\\?\\C:\\x"), "C:\\x")
        self.assertEqual(cf._strip_ext_prefix("C:\\x"), "C:\\x")
        # a junction is the place it points at
        link = os.path.join(TMP, "resolve_link")
        make_junction(link, d)
        try:
            self.assertEqual(cf.resolve_path(link), want)
            self.assertEqual(cf.resolve_path(os.path.join(link, "child")), os.path.join(want, "child"))
        finally:
            remove_junction(link)

    def test_every_python_tool_exits_2_and_writes_nothing(self):
        with FakeRepo() as fr:
            paths = [os.path.join(fr.backend, "zz_out"), os.path.join(fr.root, "phone_src", "zz_out"), os.path.join(fr.root, "zz_out"),
                     os.path.join(fr.root, "other", "..", "backend", "zz_out")]
            for pth in paths:
                for label, call in tool_calls(pth):
                    buf = io.StringIO()
                    with self.subTest(tool=label, path=pth), contextlib.redirect_stdout(buf):
                        code = call()
                    self.assertEqual(code, 2, (label, buf.getvalue()))
                    self.assertNotIn("zz_out", buf.getvalue())   # the message does not repeat the path either
            self.assertEqual(fr.files(), [])
            self.assertFalse(any(os.path.exists(p) or os.path.exists(p + ".json") for p in paths))

    def test_an_alternate_data_stream_is_refused(self):
        with FakeRepo("fake_repo_ads") as fr:
            for pth in (fr.root + ":s", fr.backend + ":s", os.path.join(TMP, "ok_dir") + ":s", os.path.join(TMP, "f.json:s"),
                        "\\\\?\\" + fr.root + ":s"):
                self.assertTrue(cf.out_path_refused(pth), pth)
            for label, call in tool_calls(fr.root + ":zz"):
                buf = io.StringIO()
                with self.subTest(tool=label), contextlib.redirect_stdout(buf):
                    code = call()
                self.assertEqual(code, 2, (label, buf.getvalue()))
            self.assertEqual(fr.files(), [])
        self.assertFalse(cf.out_path_refused(r"C:\Users\someone\scratch\x"))   # the drive colon alone is fine

    def test_the_temp_folder_is_checked_before_it_is_used(self):
        with FakeRepo("fake_repo_temp") as fr:
            before = sorted(os.listdir(fr.root))
            with mock.patch.object(tempfile, "tempdir", fr.root), mock.patch.dict(cf._SERVER, {"mod": None}):
                with self.assertRaises(cf.OutPathRefused):
                    cf.load_server()
            self.assertEqual(sorted(os.listdir(fr.root)), before)
            for k in ("TMPDIR", "TEMP", "TMP"):   # an environment variable alone, tempfile not asked yet
                with self.subTest(var=k), mock.patch.object(tempfile, "tempdir", None), mock.patch.dict(os.environ, {k: fr.root}), \
                        mock.patch.dict(cf._SERVER, {"mod": None}):
                    with self.assertRaises(cf.OutPathRefused):
                        cf.load_server()
                self.assertEqual(sorted(os.listdir(fr.root)), before)

    def test_junction_short_name_and_extended_paths_to_a_forbidden_place(self):
        with FakeRepo("fake_repo_alias") as fr:
            links = os.path.join(TMP, "alias_links")
            os.makedirs(links, exist_ok=True)
            top = os.path.join(links, "to_backend")
            make_junction(top, fr.backend)
            try:
                spellings = {"junction": os.path.join(top, "zz_out"), "extended": "\\\\?\\" + os.path.join(fr.backend, "zz_out"),
                             "device": "\\\\.\\" + os.path.join(fr.backend, "zz_out"), "upper": os.path.join(fr.backend, "zz_out").upper()}
                sn = short_name(fr.backend)
                if sn and sn.lower() != fr.backend.lower():
                    spellings["short83"] = os.path.join(sn, "zz_out")
                for name, pth in spellings.items():
                    self.assertTrue(cf.out_path_refused(pth), name)
                    for label, call in tool_calls(pth):
                        buf = io.StringIO()
                        with self.subTest(spelling=name, tool=label), contextlib.redirect_stdout(buf):
                            code = call()
                        self.assertEqual(code, 2, (name, label, buf.getvalue()))
                self.assertEqual(fr.files(), [])
            finally:
                remove_junction(top)

    def test_a_junction_below_a_fine_out_folder_is_caught_at_every_file(self):
        import numpy as np
        from types import SimpleNamespace
        with FakeRepo("fake_repo_nested") as fr:
            out = os.path.join(TMP, "nested_out")
            os.makedirs(out, exist_ok=True)
            link = os.path.join(out, "clips")
            self.assertFalse(cf.out_path_refused(out))              # the top --out is fine ...
            make_junction(link, os.path.join(fr.root, "other"))      # ... its clips\ folder is a junction into the forbidden place
            try:
                self.assertTrue(cf.out_path_refused(os.path.join(link, "x.wav")))
                server = SimpleNamespace(en_words=lambda t: t.lower().split(), available_voices=lambda *_: ["voice"])
                buf = io.StringIO()
                with mock.patch.object(cf, "load_server", lambda **_: server), \
                        mock.patch.object(ms, "synth16", lambda *_: np.zeros(16000, dtype=np.float32)), contextlib.redirect_stdout(buf):
                    code = ms.main(["--out", out, "--n-sentences", "1", "--voices", "1"])
                self.assertEqual(code, 2, buf.getvalue())
                self.assertEqual(fr.files(), [])
                self.assertFalse(os.path.exists(os.path.join(out, "manifest.json")))
                # the same junction hits the other writers too: a recorded clip and the pc json
                with self.assertRaises(cf.OutPathRefused):
                    rec.write_wav(os.path.join(link, "u01_clean.wav"), np.zeros(1600, dtype=np.int16))
                with self.assertRaises(cf.OutPathRefused):
                    ms.write_wav16(os.path.join(link, "c.wav"), np.zeros(1600, dtype=np.float32))
                with self.assertRaises(cf.OutPathRefused):
                    ms.write_json(os.path.join(link, "manifest.json"), {})
                with self.assertRaises(cf.OutPathRefused):
                    cf._write_json(os.path.join(link, "report.json"), {})
                self.assertEqual(fr.files(), [])
            finally:
                remove_junction(link)

    def test_selfcheck_scratch_is_not_refused_and_the_guard_lets_it_write(self):
        import numpy as np
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            code = rec.main(["--out", os.path.join(TMP, "dry_ok"), "--dry-run"])
        self.assertEqual(code, 0)
        p = os.path.join(TMP, "guard_ok", "c.wav")
        self.assertGreater(ms.write_wav16(p, np.zeros(1600, dtype=np.float32)), 0)
        self.assertTrue(os.path.exists(p))

    @unittest.skipUnless(os.path.isfile(GODOT) and os.path.isdir(os.path.join(ROOT, "godot", ".godot")), "Godot or the imported project is missing")
    def test_calib_phone_gd_refuses_res_user_relative_repo_extended_and_short_name_paths(self):
        env = dict(os.environ, APPDATA=os.path.join(TMP, "gd_appdata"))
        os.makedirs(env["APPDATA"], exist_ok=True)
        cases = [("res://zz_probe_out.json", True), ("user://zz_probe_out.json", True), ("zz_probe_out.json", True),
                 (os.path.join(ROOT, "zz_probe_out.json"), True), (os.path.join(ROOT, "backend", "zz.json"), True),
                 (r"D:\Ai\언어\app\zz_probe_out.json", True), (r"D:/Ai/언어/app_wt/zz_probe_out.json", True),
                 (os.path.join(ROOT, "godot", "zz.json"), True),
                 ("\\\\?\\" + os.path.join(TMP, "gd_ext.json"), True), ("\\\\.\\" + os.path.join(TMP, "gd_dev.json"), True),
                 ("//?/" + os.path.join(TMP, "gd_ext2.json").replace("\\", "/"), True),
                 (r"C:\PROGRA~1\zz.json", True), (os.path.join(TMP, "a~b", "gd_tilde.json"), True), (r"D:\Ai\~1\zz.json", True)]
        if "~" not in TMP:
            cases.append((os.path.join(TMP, "gd_ok.json"), False))
        for out, expect_refused in cases:
            r = subprocess.run([GODOT, "--headless", "--path", os.path.join(ROOT, "godot"), "-s", "res://tools/calib_phone.gd", "--",
                                "--model=" + os.path.join(TMP, "nomodel.bin"), "--set=" + TMP, "--out=" + out],
                               capture_output=True, env=env, cwd=TMP)
            text = r.stdout.decode("utf-8", "replace")
            with self.subTest(out=out):
                if expect_refused:
                    self.assertEqual(r.returncode, 2, text)
                    self.assertIn("CALIB_PHONE_FAIL out_path", text)
                else:
                    self.assertNotIn("out_path", text)
                self.assertFalse(os.path.exists(os.path.join(ROOT, "zz_probe_out.json")))
                self.assertFalse(os.path.exists(os.path.join(ROOT, "godot", "zz_probe_out.json")))

    def test_the_junction_limit_of_the_gd_tool_is_written_down(self):
        gd = open(os.path.join(ROOT, "godot", "tools", "calib_phone.gd"), encoding="utf-8").read()
        readme = open(os.path.join(ROOT, "phone_src", "calib", "README.txt"), encoding="utf-8").read()
        for text in (gd.split("const CHUNK_SECONDS")[0], readme):
            self.assertIn("정션", text)
            self.assertIn("알려진 한계", text)


MARKERS = ("ZQSECRET", "ZQFILE", "ZQMODEL", "ZQDATE", "ZQWORDS")


def leaks(text):
    return [m for m in MARKERS if m in text]


class NoInputInOutput(unittest.TestCase):
    """no file name, clip id, sentence, model name or date of the user's files appears in stdout or in the report"""

    def go(self, pc, ph, tag="ZQFILE_run", extra=()):
        code, out, params, report = run_cli(pc, ph, tag, extra)
        rep = open(report, encoding="utf-8").read() if os.path.exists(report) else ""
        return code, out, rep

    def test_selfcheck_the_leak_scan_sees_a_marker(self):
        self.assertEqual(leaks("a ZQSECRET b"), ["ZQSECRET"])

    def test_bad_inputs_leave_no_marker(self):
        pc, ph = FIX["good"]
        cases = {}
        a = copy.deepcopy(pc)
        a["clips"][0]["id"] = "ZQSECRET one two three"
        a["clips"][0]["words"] = {}
        cases["words not a list"] = (a, ph)
        b = copy.deepcopy(ph)
        b["model"] = "ggml-ZQMODEL secret words.bin"
        cases["bad model name"] = (pc, b)
        c = dict(copy.deepcopy(pc), date="2026-ZQDATE")
        cases["bad date"] = (c, ph)
        d = copy.deepcopy(ph)
        d["clips"][0]["id"] = "ZQSECRET dup"
        d["clips"][1]["id"] = "ZQSECRET dup"
        cases["duplicate id"] = (pc, d)
        e = copy.deepcopy(ph)
        e["clips"][0]["id"] = "ZQSECRET only on the phone side"
        cases["one sided"] = (pc, e)
        f = copy.deepcopy(ph)
        f["clips"][0]["ok"] = False
        f["clips"][0]["text"] = "ZQSECRET said this"
        f["clips"][0]["id"] = "ZQSECRET failed"
        pcf = copy.deepcopy(pc)
        pcf["clips"][0]["id"] = "ZQSECRET failed"
        cases["phone clip failed"] = (pcf, f)
        g = copy.deepcopy(pc)
        g["clips"][0]["score"]["units"].pop()
        g["clips"][0]["target"] = "ZQSECRET target words are right here now"
        cases["units mismatch"] = (g, ph)
        h = copy.deepcopy(pc)
        h["clips"][0]["words"][0].pop("p")
        h["clips"][0]["id"] = "ZQSECRET nop"
        cases["word without p"] = (h, ph)
        for name, (x, y) in cases.items():
            with self.subTest(name):
                code, out, rep = self.go(x, y)
                self.assertEqual(code, 1, out)
                self.assertEqual(leaks(out), [], out)
                self.assertEqual(leaks(rep), [], rep)

    def test_unreadable_file_name_is_not_repeated(self):
        buf = io.StringIO()
        rpt = os.path.join(TMP, "ZQFILE_rep.json")
        with contextlib.redirect_stdout(buf):
            code = cf.main(["--pc", os.path.join(TMP, "ZQFILE_nothing.json"), "--phone", os.path.join(TMP, "ZQFILE_nothing2.json"),
                            "--out-params", os.path.join(TMP, "ZQFILE_p.json"), "--report", rpt])
        self.assertEqual(code, 1)
        self.assertEqual(leaks(buf.getvalue()), [])
        self.assertEqual(leaks(open(rpt, encoding="utf-8").read()), [])
        self.assertIn("file 1", buf.getvalue())   # named by number

    def test_probe_style_malformed_input(self):
        pcp = dump({"clips": [{"id": "ZQSECRET private spoken words", "words": {}}]}, "ZQFILE_pc2.json")
        php = dump({"clips": []}, "ZQFILE_ph2.json")
        rpt = os.path.join(TMP, "ZQFILE_rep2.json")
        args = cf.build_parser().parse_args(["--pc", pcp, "--phone", php, "--out-params", os.path.join(TMP, "ZQFILE_never.json"), "--report", rpt])
        lines = []
        ret = cf.run(args, S=object(), out=lines.append)
        self.assertEqual(ret, 1)
        self.assertEqual(leaks("\n".join(lines) + open(rpt, encoding="utf-8").read()), [])

    def test_allowed_model_name_and_date_do_reach_the_report(self):
        code, out, rep = self.go(*FIX["good"], tag="ok_names")
        self.assertEqual(code, 0, out)
        r = json.loads(rep)
        self.assertEqual((r["model_id"], r["date"]), ("whisper-base.en-q5_1", "2026-11-19"))

    def test_tool_messages_hold_no_input_text(self):
        for src in ("calib_make_set.py", "calib_pc_run.py", "calib_fit.py"):
            text = open(os.path.join(HERE, src), encoding="utf-8").read()
            self.assertNotRegex(text, r"str\(e\)\[:200\]", src)   # an exception text may carry a file name, a sentence or a transcript
        self.assertNotIn("basename", open(os.path.join(HERE, "calib_fit.py"), encoding="utf-8").read().split("def read_run")[1].split("def join_clips")[0])


class WordTimes(unittest.TestCase):
    """D-1 (docs/v201_design.md 8.1): the same cases are copied into the GDScript test of PA4"""

    def w(self, *pairs):
        return [{"w": "w%d" % i, "p": 0.5 + i / 100.0, "start": a, "end": b} for i, (a, b) in enumerate(pairs)]

    def times(self, words, clip):
        return [(x["start"], x["end"]) for x in cf.clean_word_times(words, clip)]

    def test_rule_cases(self):
        nan, inf = float("nan"), float("inf")
        cases = [
            ("1 not finite -> 0", [(nan, 1.0), (0.5, inf)], 3.0, [(0.0, 0.5), (0.5, 0.5)]),   # w1 end inf = 0 -> 0.5 (its start); w0 end 1.0 -> next start 0.5
            ("2 cut to [0, clip]", [(-1.0, 5.0)], 3.0, [(0.0, 3.0)]),
            ("3 start never goes back; end never before start; end <= next start", [(0.5, 1.0), (0.2, 0.4)], 2.0, [(0.5, 0.5), (0.5, 0.5)]),
            ("5 end cut to the next start", [(0.0, 1.0), (0.6, 1.5)], 3.0, [(0.0, 0.6), (0.6, 1.5)]),
            ("the real case: whisper.cpp spreads over 30 s, the clip is 2.075 s", [(0.07, 5.52), (5.52, 9.62), (9.62, 15.07)], 2.075,
             [(0.07, 2.075), (2.075, 2.075), (2.075, 2.075)]),
            ("6 no rounding", [(0.123456789, 0.987654321)], 5.0, [(0.123456789, 0.987654321)]),
            ("fine input stays", [(0.0, 0.4), (0.45, 0.85), (0.9, 1.3)], 2.0, [(0.0, 0.4), (0.45, 0.85), (0.9, 1.3)]),
            ("clip length 0", [(0.1, 0.2)], 0.0, [(0.0, 0.0)]),
            ("empty", [], 1.0, []),
        ]
        for name, pairs, clip, expect in cases:
            with self.subTest(name):
                self.assertEqual(self.times(self.w(*pairs), clip), expect)

    def test_none_and_text_count_as_not_finite(self):
        ws = [{"w": "a", "p": 0.5, "start": None, "end": "x"}, {"w": "b", "p": 0.5, "start": 0.3, "end": 0.6}]
        self.assertEqual(self.times(ws, 1.0), [(0.0, 0.0), (0.3, 0.6)])

    def test_order_count_words_and_probabilities_are_kept_and_the_input_is_not_changed(self):
        ws = self.w((0.5, 1.0), (0.2, 0.4), (9.0, 12.0))
        before = copy.deepcopy(ws)
        out = cf.clean_word_times(ws, 2.0)
        self.assertEqual(ws, before)
        self.assertEqual([(x["w"], x["p"]) for x in out], [(x["w"], x["p"]) for x in ws])
        starts = [x["start"] for x in out]
        self.assertEqual(starts, sorted(starts))
        for x in out:
            self.assertTrue(0.0 <= x["start"] <= x["end"] <= 2.0)

    def test_selfcheck_a_wrong_rule_would_differ(self):
        self.assertNotEqual(self.times(self.w((0.5, 1.0), (0.2, 0.4)), 2.0), [(0.5, 1.0), (0.2, 0.4)])   # the raw times are not the cleaned ones

    def test_fluency_is_scored_on_the_cleaned_times(self):
        pc, ph = FIX["good"]
        pcc = dict(pc["clips"][0], sentence_id="s")
        phc = copy.deepcopy(ph["clips"][0])
        t = 0.0
        for w in phc["words"]:   # the bridge's habit: the words spread over a 30 s window while the clip lasts 2.5 s
            w["start"], w["end"], t = t, t + 6.0, t + 6.0
        ident = [[0.0, 0.0], [1.0, 1.0]]
        try:
            cf.RETIME = False
            raw = cf.phone_result(S, pcc, phc, ident, 0.45)["fluency"]
            cf.RETIME = True
            clean = cf.phone_result(S, pcc, phc, ident, 0.45)["fluency"]
        finally:
            cf.RETIME = True
        self.assertLess(raw, 60)
        self.assertGreater(clean, raw)
        self.assertGreaterEqual(clean, 90)


class WordTimesAtTheEntry(unittest.TestCase):
    """D-1 step 1 at the CLI entry: a start / end that is NaN, infinite, null or missing is 0, not an error; w and p are still checked"""

    def test_read_run_turns_unusable_times_into_zero(self):
        doc = {"clips": [{"id": "a", "ok": True, "duration": 2.0, "text": "",
                          "words": [{"w": "x", "p": 0.5, "start": float("nan"), "end": float("inf")},
                                    {"w": "y", "p": 0.5, "start": None, "end": "soon"}, {"w": "z", "p": 0.5}]}]}
        _h, clips = cf.read_run(dump(doc, "d1_entry.json"), "phone")
        self.assertEqual([(w["start"], w["end"]) for w in clips["a"]["words"]], [(0.0, 0.0)] * 3)

    def test_w_and_p_are_still_checked(self):
        for bad in ({"w": "x", "start": 0.0, "end": 1.0}, {"w": 5, "p": 0.5, "start": 0.0, "end": 1.0},
                    {"w": "x", "p": float("nan"), "start": 0.0, "end": 1.0}, {"w": "x", "p": None, "start": 0.0, "end": 1.0}):
            doc = {"clips": [{"id": "a", "ok": True, "duration": 2.0, "words": [bad]}]}
            with self.subTest(bad=str(bad)), self.assertRaises(cf.CalibError):
                cf.read_run(dump(doc, "d1_bad.json"), "phone")

    def test_the_cli_goes_on_to_cleaning_and_fitting(self):
        pc, ph = FIX["good"]
        finite = copy.deepcopy(ph)
        for c in finite["clips"][:6]:
            c["words"][0]["start"] = 0.0
        for label, value in (("nan", float("nan")), ("null", None), ("inf", float("inf")), ("minus_inf", float("-inf"))):
            bad = copy.deepcopy(ph)
            for c in bad["clips"][:6]:
                if value is None:
                    c["words"][0]["start"] = None
                else:
                    c["words"][0]["start"] = value
            code, out, params, report = run_cli(pc, bad, "d1_" + label)
            with self.subTest(label):
                self.assertNotIn("CALIB_FAIL input", out)
                self.assertIn("score_mae", out)   # the run reached the judging
                self.assertIn(code, (0, 1))
            code0, out0, _p0, report0 = run_cli(pc, finite, "d1_zero_" + label)
            with self.subTest(label + " equals 0.0"):   # the same result as a file that has a 0 there
                self.assertEqual(open(report, encoding="utf-8").read(), open(report0, encoding="utf-8").read())
        # a missing start key is the same
        miss = copy.deepcopy(ph)
        for c in miss["clips"][:6]:
            c["words"][0].pop("start")
        code, out, _p, _r = run_cli(pc, miss, "d1_missing")
        self.assertNotIn("CALIB_FAIL input", out)

    def test_selfcheck_a_non_number_that_is_not_a_time_problem_still_fails(self):
        pc, ph = FIX["good"]
        bad = copy.deepcopy(ph)
        bad["clips"][0]["words"][0]["p"] = None
        code, out, _p, _r = run_cli(pc, bad, "d1_pnull")
        self.assertEqual((code, "CALIB_FAIL input" in out), (1, True))


class SentenceGroups(unittest.TestCase):
    def test_same_normalized_target_is_one_group_whatever_the_id(self):
        rows = [({"sentence_id": "a", "target": "We can walk home."}, {}), ({"sentence_id": "b", "target": "we can WALK home"}, {}),
                ({"sentence_id": "c", "target": "Something else entirely."}, {}), ({"sentence_id": "d", "target": "Another sentence here."}, {})]
        for seed in range(1, 40):
            train, held = cf.split_sentences(rows, seed, 0.5, S)
            side = [{r[0]["sentence_id"] for r in train}, {r[0]["sentence_id"] for r in held}]
            self.assertTrue(any({"a", "b"} <= x for x in side), "seed %d split a and b" % seed)

    def test_selfcheck_by_id_alone_would_split_them(self):
        keys = {"a": 1, "b": 2}
        self.assertNotEqual(keys["a"], keys["b"])   # the old key (the id) puts the two on different sides for some seed
        crossed = 0
        for seed in range(1, 40):
            ids = ["a", "b", "c", "d"]
            random.Random(seed).shuffle(ids)
            hold = set(ids[:2])
            crossed += ("a" in hold) != ("b" in hold)
        self.assertGreater(crossed, 0)

    def test_pool_has_one_entry_per_normalized_sentence(self):
        pool = ms.load_pool()
        self.assertEqual(len({ms.norm_key(t) for _i, t in pool}), len(pool))
        lowered = {t.lower() for _i, t in pool}
        self.assertLessEqual(len(lowered), len(pool))

    def test_seed_45_plan_has_no_normalized_target_on_both_sides(self):
        pool = ms.load_pool(3, 10, 200)
        chosen = ms.pick_sentences(pool, 200, 45)
        user = [(sid, text) for sid, text, _w, _s in rec.plan(11)]
        rows = [({"sentence_id": sid, "target": text}, None) for sid, text in chosen + user]
        for seed in (45, 7, 11):
            train, held = cf.split_sentences(rows, seed, 0.3, S)
            a = {ms.norm_key(r[0]["target"]) for r in train}
            b = {ms.norm_key(r[0]["target"]) for r in held}
            self.assertTrue(a and b)
            self.assertEqual(a & b, set(), "seed %d" % seed)
        # a chosen sentence and a user sentence with the same words are in the same group (they come from one deduplicated pool)
        both = {ms.norm_key(t) for _i, t in chosen} & {ms.norm_key(t) for _i, t in user}
        for key in both:
            ids = {r[0]["sentence_id"] for r in rows if ms.norm_key(r[0]["target"]) == key}
            self.assertEqual(len(ids), 1)

    def test_course_sentences_only_when_practice_is_short(self):
        base = ms.load_pool(3, 10, 0)
        self.assertEqual(ms.load_pool(3, 10, 200), base)
        self.assertEqual(ms.load_pool(3, 10, len(base)), base)
        more = ms.load_pool(3, 10, len(base) + 1)
        self.assertGreaterEqual(len(more), len(base))
        practice_ids = {str(x["id"]) for x in ms._read_json(ms.PRACTICE_PATH)["sentences"]}
        self.assertTrue(all(i in practice_ids for i, _t in base))


class PhoneFailures(unittest.TestCase):
    def test_a_phone_clip_that_failed_is_a_data_error(self):
        pc, ph = FIX["good"]
        bad = copy.deepcopy(ph)
        bad["clips"][3]["ok"] = False
        bad["clips"][3]["error"] = "engine"
        bad["clips"][3]["words"] = []
        code, out, params, _r = run_cli(pc, bad, "phfail")
        self.assertEqual(code, 1, out)
        self.assertIn("CALIB_FAIL data", out)
        self.assertFalse(os.path.exists(params))
        noflag = copy.deepcopy(ph)
        noflag["clips"][3].pop("ok")
        code, out, params, _r = run_cli(pc, noflag, "phnoflag")
        self.assertEqual((code, "CALIB_FAIL data" in out), (1, True))
        marked = dict(copy.deepcopy(ph), status="fail")
        code, out, params, _r = run_cli(pc, marked, "phmarked")
        self.assertEqual((code, "CALIB_FAIL data" in out), (1, True))
        nolen = copy.deepcopy(ph)
        nolen["clips"][0].pop("duration")
        code, out, params, _r = run_cli(pc, nolen, "phnolen")
        self.assertEqual((code, "CALIB_FAIL input" in out), (1, True))

    def test_selfcheck_the_good_phone_file_passes(self):
        code, out, params, _r = run_cli(*FIX["good"], "phok")
        self.assertEqual(code, 0, out)

    @unittest.skipUnless(os.path.isfile(GODOT) and os.path.isdir(os.path.join(ROOT, "godot", ".godot"))
                         and os.path.isfile(os.path.join(ROOT, "godot", "whisper_bridge.gdextension")), "needs the native bridge (N0)")
    def test_calib_phone_gd_fails_on_a_clip_it_cannot_transcribe(self):
        model = os.path.join(r"C:\Users\rtyu6\AppData\Local\Temp\claude\D--Ai----app\c5535f7a-0e1a-4bb6-bdc3-5597b7f84c22\scratchpad", "w_v200pa1", "models", "ggml-base.en-q5_1.bin")
        if not os.path.isfile(model):
            self.skipTest("model file missing")
        d = os.path.join(TMP, "gd_bad_set")
        os.makedirs(os.path.join(d, "clips"), exist_ok=True)
        with open(os.path.join(d, "clips", "a.wav"), "wb") as f:
            f.write(b"\x00\x01\x02\x03")
        with open(os.path.join(d, "manifest.json"), "w", encoding="utf-8") as f:
            json.dump({"clips": [{"clip": "a", "file": "clips/a.wav"}]}, f)
        env = dict(os.environ, APPDATA=os.path.join(TMP, "gd_appdata2"))
        os.makedirs(env["APPDATA"], exist_ok=True)
        outp = os.path.join(TMP, "gd_bad_out.json")
        r = subprocess.run([GODOT, "--headless", "--path", os.path.join(ROOT, "godot"), "-s", "res://tools/calib_phone.gd", "--",
                            "--model=" + model, "--set=" + d, "--out=" + outp], capture_output=True, env=env, cwd=TMP)
        text = r.stdout.decode("utf-8", "replace")
        self.assertEqual(r.returncode, 1, text)
        self.assertIn("CALIB_PHONE_FAIL transcribe", text)
        self.assertEqual(json.load(open(outp, encoding="utf-8"))["status"], "fail")


class FinalMapBoundary(unittest.TestCase):
    def rows(self, clean, wrong):
        return [({"variant": "clean"}, {"score": clean}), ({"variant": "wrong"}, {"score": wrong})]

    def test_every_step_is_a_valid_monotone_map_with_the_step_at_a(self):
        for a in range(0, 101):
            m = cf.final_map_step(a)
            with self.subTest(a=a):
                self.assertTrue(cf.valid_final_map(m), m)
                xs = [x for x, _y in m]
                self.assertEqual(len(xs), len(set(xs)), "x twice: %r" % (m,))
                if a >= 1:
                    self.assertLess(cf.map_final(a - 1, m), 70)
                self.assertGreaterEqual(cf.map_final(a, m), 70)
                ys = [cf.map_final(v, m) for v in range(0, 101)]
                self.assertEqual(ys, sorted(ys))

    def test_threshold_100_with_clean_100_and_wrong_99(self):
        with mock.patch.object(cf, "phone_result", lambda _S, _pc, ph, *a: ph):
            m = cf.fit_final_map(None, self.rows(100, 99), [], 0.45)
        self.assertIsNotNone(m)
        self.assertTrue(cf.valid_final_map(m))
        self.assertEqual(len({x for x, _y in m}), len(m))
        self.assertGreaterEqual(cf.map_final(100, m), 70)
        self.assertLess(cf.map_final(99, m), 70)

    def test_threshold_0_and_1_and_the_old_example_shape(self):
        with mock.patch.object(cf, "phone_result", lambda _S, _pc, ph, *a: ph):
            m0 = cf.fit_final_map(None, self.rows(100, 100)[:1] + [({"variant": "wrong"}, {"score": 0})], [], 0.45)
            self.assertIsNotNone(m0)
            self.assertLess(cf.map_final(0, m0), 70)
        self.assertEqual(cf.final_map_step(70), [[0, 0], [100, 100]])
        self.assertTrue(cf.valid_final_map([[0, 0], [99, 69], [100, 70]]))

    def test_no_step_when_clean_equals_wrong(self):
        with mock.patch.object(cf, "phone_result", lambda _S, _pc, ph, *a: ph):
            self.assertIsNone(cf.fit_final_map(None, self.rows(90, 90), [], 0.45))


class OfflineModels(unittest.TestCase):
    def test_models_are_loaded_from_local_files_only(self):
        self.assertEqual(S._load_whisper.__name__, "_load_whisper_local")
        self.assertEqual(os.environ.get("HF_HUB_OFFLINE"), "1")
        src = open(os.path.join(HERE, "calib_fit.py"), encoding="utf-8").read()
        self.assertEqual(src.count("local_files_only=True)"), 1)


# ================================================================================================ REC: input device, sound check, 16 kHz
class FakeSd:
    """a stand-in for the sounddevice module: a device list like this PC's (a game pad is the Windows default and comes first, WDM-KS
    entries exist, MME cuts a name at 31 letters). It records what is opened: `calls` has one entry per rec / InputStream call."""

    def __init__(self, signal=None, default=(1, 5), supply=None, flag_block=None):
        """supply(open_number, rate) -> how many frames the stream delivers before it goes quiet (default 10 s: more than any clip);
        flag_block(open_number, block_number) -> True makes that callback carry a status (an overflow)"""
        import types
        self.default = types.SimpleNamespace(device=default)
        self.calls = []
        self.queries = 0
        self.opened = 0
        self.closed = 0
        self.signal = signal or sine_signal()
        self.supply = supply or (lambda n, rate: 10 * rate)
        self.flag_block = flag_block or (lambda n, b: False)
        self.hostapis = [{"name": "MME"}, {"name": "Windows DirectSound"}, {"name": "Windows WASAPI"}, {"name": "Windows WDM-KS"}]
        zoom_full = "마이크(ZOOM H and F Series Async Audio)"
        pad = "헤드셋 마이크(Wireless Controller)"
        shokz = "헤드셋 기본 설정(OpenRun Pro 2 by Shokz)"

        def dev(name, api, ch, sr):
            return {"name": name, "hostapi": api, "max_input_channels": ch, "max_output_channels": 0, "default_samplerate": float(sr)}
        self.devices = [
            dev("Microsoft 사운드 매퍼 - Input", 0, 2, 44100),            # 0 mapper (hidden)
            dev(pad, 0, 1, 44100),                                          # 1 game pad (the Windows default)
            dev(zoom_full[:31], 0, 2, 44100),                               # 2 ZOOM, name cut by MME
            dev(shokz[:31], 0, 1, 44100),                                   # 3 Shokz, name cut by MME
            dev("주 사운드 캡처 드라이버", 1, 2, 44100),                     # 4 primary capture (hidden)
            dev(pad, 1, 1, 44100),                                          # 5 game pad
            dev(zoom_full, 1, 2, 44100),                                    # 6 ZOOM
            dev(shokz, 1, 1, 44100),                                        # 7 Shokz
            dev(zoom_full, 2, 2, 48000),                                    # 8 ZOOM WASAPI (48 kHz only)
            dev(pad, 2, 2, 48000),                                          # 9 game pad WASAPI
            dev(shokz, 2, 1, 16000),                                        # 10 Shokz WASAPI
            dev(pad, 3, 1, 16000),                                          # 11 WDM-KS
            dev("마이크 (ZOOM H and F Series Async Audio Wave)", 3, 2, 44100),   # 12 WDM-KS
            {"name": "스피커(ZOOM)", "hostapi": 0, "max_input_channels": 0, "max_output_channels": 2, "default_samplerate": 44100.0},  # 13
        ]

    def query_hostapis(self):
        self.queries += 1
        return self.hostapis

    def query_devices(self):
        self.queries += 1
        return self.devices

    def InputStream(self, samplerate=None, channels=None, dtype=None, device=None, callback=None, **k):
        self.calls.append({"kind": "InputStream", "rate": samplerate, "channels": channels, "device": device})
        self.opened += 1
        return FakeStream(self, self.opened, samplerate, channels, device, callback)


class FakeStatus:
    def __bool__(self):
        return True


class FakeStream:
    """start() hands the signal to the callback in blocks of 1024 frames, like the audio thread, then stays quiet"""

    def __init__(self, sd, number, rate, channels, device, callback):
        self.sd, self.number, self.rate, self.channels, self.device, self.callback = sd, number, rate, channels, device, callback
        self.stopped = self.is_closed = False

    def start(self):
        total = int(self.sd.supply(self.number, self.rate))
        data = self.sd.signal(total, self.rate, self.channels, self.device)
        for b, i in enumerate(range(0, total, 1024)):
            block = data[i:i + 1024]
            self.callback(block, len(block), None, FakeStatus() if self.sd.flag_block(self.number, b) else None)

    def stop(self):
        self.stopped = True

    def close(self):
        self.is_closed = True
        self.sd.closed += 1


def sine_signal(freq=1000.0, amp=0.5, per_device=None):
    import numpy as np

    def f(frames, rate, channels, device):
        a = (per_device or {}).get(device, amp)
        t = np.arange(frames) / float(rate)
        x = (a * np.sin(2 * math.pi * freq * t)).astype("float32")
        return np.stack([x] * channels, axis=1)
    return f


def peak_freq(x, rate):
    import numpy as np
    x = np.asarray(x, dtype="float64")
    spec = np.abs(np.fft.rfft(x * np.hanning(len(x))))
    return float(np.argmax(spec)) * rate / len(x)


def quiet_run(*args, **kw):
    """rec.run with a silent screen (no sleeping, no live bar): (exit code, the printed lines as one text)"""
    kw.setdefault("sleep", lambda s: None)
    kw.setdefault("live", None)
    kw.setdefault("set_tag", "s8")   # a fixed clip id prefix (pass set_tag=None for the automatic one)
    lines = []
    kw.setdefault("out", lines.append)
    with contextlib.redirect_stdout(io.StringIO()):
        code = rec.run(*args, **kw)
    return code, "\n".join(lines)


class RecordDevices(unittest.TestCase):
    def setUp(self):
        self.out_dir = os.path.join(TMP, "recdev_%d" % random.randrange(10 ** 9))

    def answers(self, items):
        it = iter(items)
        return lambda *_: next(it)

    def test_list_leaves_out_wdmks_and_does_not_recommend_the_game_pad(self):
        sd = FakeSd()
        devs = rec.list_input_devices(sd)
        self.assertFalse([d for d in devs if "wdm" in d["api"].lower()])
        self.assertEqual(sorted(d["index"] for d in devs), [1, 2, 3, 5, 6, 7, 8, 9, 10])   # mapper, primary capture, WDM-KS, output only: out
        self.assertEqual([d["index"] for d in devs if d["default"]], [1])
        self.assertTrue(all(d["gamepad"] for d in devs if "Wireless Controller" in d["name"]))
        best = rec.recommended_device(devs)
        self.assertEqual(best["index"], 2)   # not 1: it is first in the list and the Windows default, but a game pad
        # full readable names: the name MME cut at 31 letters is the full one of the same device
        names = {d["index"]: d["name"] for d in devs}
        self.assertEqual(names[2], "마이크(ZOOM H and F Series Async Audio)")
        self.assertIn("Shokz)", names[3])
        # selfcheck: with only game pads and virtual devices there is no recommendation
        only_pad = [d for d in devs if d["gamepad"]] + [dict(devs[0], virtual=True, gamepad=False)]
        self.assertIsNone(rec.recommended_device(only_pad))

    def test_list_devices_prints_names_and_opens_nothing(self):
        sd = FakeSd()
        lines = []
        self.assertEqual(rec.list_devices(out=lines.append, sd=sd), 0)
        text = "\n".join(lines)
        for frag in ("ZOOM", "Shokz", "Wireless Controller", "MME", "WASAPI", "DirectSound", "44100 Hz", "48000 Hz", "2ch", "Windows 기본 입력", "추천"):
            self.assertIn(frag, text)
        self.assertNotIn("WDM", text)
        self.assertEqual(sd.calls, [])
        rec_lines = [l for l in lines if l.rstrip().endswith("추천")]
        self.assertEqual(len(rec_lines), 1)
        self.assertTrue(rec_lines[0].lstrip().startswith("2 "))

    def test_names_that_came_through_the_ansi_code_page_are_restored(self):
        mojibake = "마이크(ZOOM)".encode("cp949").decode("latin-1")
        self.assertNotEqual(mojibake, "마이크(ZOOM)")
        self.assertEqual(rec.readable_name(mojibake), "마이크(ZOOM)")
        self.assertEqual(rec.readable_name("헤드셋 마이크"), "헤드셋 마이크")   # already right: unchanged
        self.assertEqual(rec.readable_name("ZOOM\r\nH4"), "ZOOM H4")
        self.assertEqual(rec.readable_name("Mic\xe9"), "Mic\xe9")   # not Korean: left alone

    def test_device_by_number_and_by_part_of_a_name(self):
        for spec, want in (("2", 2), ("8", 8), ("zoom", 2), ("ZOOM", 2), ("shokz", 3), ("Wireless", 1), ("마이크(ZOOM", 2), (" 6 ", 6)):
            sd = FakeSd()
            code, text = quiet_run(self.out_dir, False, 11, input_fn=self.answers(["y", "q"]), sd=sd, device=spec)
            self.assertEqual(code, 0, spec)
            self.assertEqual({c["device"] for c in sd.calls}, {want}, spec)
        for bad in ("12", "0", "4", "99", "nothing-like-this", ""):   # WDM-KS, mapper, primary capture, unknown, no match
            sd = FakeSd()
            with self.assertRaises(rec.RecError) as cm:
                quiet_run(self.out_dir, False, 11, input_fn=self.answers(["y"]), sd=sd, device=bad)
            self.assertEqual(str(cm.exception), "device")   # no device name in the error
            self.assertEqual(sd.calls, [], bad)
        self.assertFalse(os.path.exists(self.out_dir))

    def test_without_device_the_list_is_shown_after_consent_and_enter_takes_the_recommended_one(self):
        sd = FakeSd()
        code, text = quiet_run(self.out_dir, False, 11, input_fn=self.answers(["y", "", "q"]), sd=sd)
        self.assertEqual(code, 0)
        self.assertIn("입력 장치", text)
        self.assertEqual({c["device"] for c in sd.calls}, {2})
        # a wrong number is asked again, a good number is taken
        sd = FakeSd()
        code, text = quiet_run(self.out_dir, False, 11, input_fn=self.answers(["y", "abc", "12", "8", "q"]), sd=sd)
        self.assertEqual({c["device"] for c in sd.calls}, {8})
        self.assertEqual(text.count("목록에 없는 번호예요"), 2)
        # five bad answers in a row: stop (no recording)
        sd = FakeSd()
        with self.assertRaises(rec.RecError):
            quiet_run(self.out_dir, False, 11, input_fn=self.answers(["y"] + ["99"] * 5), sd=sd)
        self.assertEqual(sd.calls, [])

    def test_nothing_is_opened_before_the_consent(self):
        for answer in ("Y", "yes", "", "n", " Y ", "YES", "yy", "ㅡ"):
            sd = FakeSd()
            recorder_calls = []
            code, text = quiet_run(self.out_dir, False, 11, input_fn=lambda *_, a=answer: a, sd=sd)
            self.assertEqual((code, sd.calls, sd.queries), (1, [], 0), repr(answer))
            code, text = quiet_run(self.out_dir, False, 11, input_fn=lambda *_, a=answer: a, sd=sd,
                                   recorder=lambda *_: recorder_calls.append(1))
            self.assertEqual((code, recorder_calls, sd.calls), (1, [], []), repr(answer))
            self.assertFalse(os.path.exists(self.out_dir))
        # a dry run lists nothing and opens nothing either
        sd = FakeSd()
        code, text = quiet_run(self.out_dir, True, 11, input_fn=lambda *_: self.fail("asked"), sd=sd)
        self.assertEqual((code, sd.calls, sd.queries), (0, [], 0))
        self.assertFalse(os.path.exists(self.out_dir))
        # selfcheck: after a real y the fake IS opened (the counters above are not blind)
        sd = FakeSd()
        quiet_run(self.out_dir, False, 11, input_fn=self.answers(["y", "", "q"]), sd=sd)
        self.assertGreater(len(sd.calls), 0)
        self.assertGreater(sd.queries, 0)

    def test_48k_device_is_recorded_at_its_own_rate_and_stored_at_16k(self):
        import numpy as np
        import soundfile as sf
        # the checker must fail on a wrong input: a 2 kHz tone is not 1 kHz
        self.assertGreater(abs(peak_freq(np.sin(2 * math.pi * 2000 * np.arange(96000) / 48000.0), 48000) - 1000.0), 10.0)
        sd = FakeSd()
        code, text = quiet_run(self.out_dir, False, 11, input_fn=self.answers(["y", "", "", "q"]), sd=sd, device="8")
        self.assertEqual(code, 0)
        self.assertEqual({c["rate"] for c in sd.calls}, {48000})   # never asked for 16 kHz from a device that does not take it
        data, sr = sf.read(os.path.join(self.out_dir, "clips", "s8_u01_clean.wav"), dtype="int16")
        self.assertEqual((sr, data.ndim), (16000, 1))
        self.assertAlmostEqual(len(data) / 16000.0, rec.RECORD_SECONDS, delta=0.06)
        self.assertAlmostEqual(peak_freq(data, 16000), 1000.0, delta=10.0)
        self.assertAlmostEqual(float(np.abs(data).max()) / 32767.0, 0.5, delta=0.03)   # the size is kept
        m = json.load(open(os.path.join(self.out_dir, "manifest.json"), encoding="utf-8"))
        self.assertEqual((m["capture_hz"], m["resampled"]), (48000, 1))
        raw = open(os.path.join(self.out_dir, "manifest.json"), encoding="utf-8").read()
        for personal in ("ZOOM", "Shokz", "Wireless", "마이크", "device"):
            self.assertNotIn(personal, raw)
        # a device that already records 16 kHz: no conversion
        sd = FakeSd()
        d2 = os.path.join(TMP, "recdev_16k")
        quiet_run(d2, False, 11, input_fn=self.answers(["y", "", "", "q"]), sd=sd, device="10")
        m = json.load(open(os.path.join(d2, "manifest.json"), encoding="utf-8"))
        self.assertEqual((m["capture_hz"], m["resampled"]), (16000, 0))

    def test_resample_works_with_scipy_when_soxr_is_missing(self):
        import numpy as np
        x = (0.5 * np.sin(2 * math.pi * 1000 * np.arange(48000 * 2) / 48000.0)).astype("float32")
        with mock.patch.dict(sys.modules, {"soxr": None}):
            y = rec.to_16k(x, 48000)
        self.assertAlmostEqual(len(y) / 16000.0, 2.0, delta=0.02)
        self.assertAlmostEqual(peak_freq(y, 16000), 1000.0, delta=10.0)
        z = rec.to_16k(x, 48000)   # soxr (installed in backend\.venv)
        self.assertAlmostEqual(len(z) / 16000.0, 2.0, delta=0.02)
        self.assertAlmostEqual(peak_freq(z, 16000), 1000.0, delta=10.0)
        w = rec.to_16k(x[:44100], 44100)   # 44.1 kHz: the ratio is not a whole number
        self.assertAlmostEqual(len(w) / 16000.0, 1.0, delta=0.02)
        self.assertEqual(len(rec.to_16k(x[:16000], 16000)), 16000)

    def test_stereo_is_averaged_and_a_silent_channel_is_left_out(self):
        import numpy as np
        dev = {"index": 2, "rate": 16000, "channels": 2}

        def pair(left, right):
            def f(frames, rate, channels, device):
                t = np.arange(frames) / float(rate)
                s = np.sin(2 * math.pi * 500 * t).astype("float32")
                return np.stack([left * s, right * s], axis=1).astype("float32")
            return f
        # both channels audible: the average
        sd = FakeSd(signal=pair(0.6, 0.3))
        frames = rec.capture(sd, dev, 1, sleep=lambda s: None)
        self.assertEqual(frames.shape, (16000, 2))
        mono, clipped, note = rec.mixdown(frames)
        self.assertEqual(mono.ndim, 1)
        self.assertAlmostEqual(float(np.abs(mono).max()), 0.45, delta=0.01)   # (0.6 + 0.3) / 2
        self.assertEqual((sd.calls[0]["channels"], clipped, note), (2, False, ""))
        mono, _, _ = rec.mixdown(rec.capture(FakeSd(signal=pair(0.6, -0.6)), dev, 1, sleep=lambda s: None))
        self.assertLess(float(np.abs(mono).max()), 0.001)   # an average, not "the left channel"
        # one channel more than 30 dB under the other (one microphone in a two channel interface): only the loud one, no 6 dB loss
        for l, r in ((0.6, 0.0), (0.0, 0.6), (0.6, 0.6 * 10 ** (-31 / 20.0))):
            mono, _, note = rec.mixdown(rec.capture(FakeSd(signal=pair(l, r)), dev, 1, sleep=lambda s: None))
            self.assertAlmostEqual(float(np.abs(mono).max()), 0.6, delta=0.01, msg=(l, r))
            self.assertIn("한 채널", note)
        mono, _, note = rec.mixdown(rec.capture(FakeSd(signal=pair(0.6, 0.6 * 10 ** (-29 / 20.0))), dev, 1, sleep=lambda s: None))
        self.assertEqual(note, "")   # only 29 dB under: still averaged
        # two silent channels: nothing to choose, no crash
        mono, _, note = rec.mixdown(np.zeros((1000, 2), dtype="float32"))
        self.assertEqual((len(mono), note), (1000, ""))
        sd = FakeSd()   # a mono device is asked for one channel
        mono, _, _ = rec.mixdown(rec.capture(sd, {"index": 1, "rate": 44100, "channels": 1}, 1, sleep=lambda s: None))
        self.assertEqual((sd.calls[0]["channels"], mono.ndim), (1, 1))
        self.assertEqual((sd.opened, sd.closed), (1, 1))   # the stream is always closed

    def test_the_stream_is_closed_even_when_stop_fails(self):
        dev = {"index": 2, "rate": 16000, "channels": 2}
        for exc in (RuntimeError("stop failed"), KeyboardInterrupt()):
            with self.subTest(exc=type(exc).__name__):
                sd = FakeSd()

                def bad_stop(self, e=exc):
                    self.stopped = True
                    raise e
                with mock.patch.object(FakeStream, "stop", bad_stop):
                    with self.assertRaises((rec.RecError, KeyboardInterrupt)):
                        rec.capture(sd, dev, 1, sleep=lambda s: None)
                self.assertEqual((sd.opened, sd.closed), (1, 1))

    def test_a_cut_or_flagged_capture_is_refused_and_never_saved(self):
        import soundfile as sf
        dev = {"index": 2, "rate": 16000, "channels": 2}
        # fewer frames than asked for (the first half only), then an overflow: both raise, the stream is closed
        sd = FakeSd(supply=lambda n, rate: 8000)
        with self.assertRaises(rec.Incomplete):
            rec.capture(sd, dev, 1, sleep=lambda s: None)
        self.assertEqual((sd.opened, sd.closed), (1, 1))
        sd = FakeSd(flag_block=lambda n, b: b == 3)   # all frames arrive but one callback carried a status
        with self.assertRaises(rec.Incomplete):
            rec.capture(sd, dev, 1, sleep=lambda s: None)
        sd = FakeSd(supply=lambda n, rate: 8000, flag_block=lambda n, b: b == 2)   # the reviewer's case: half filled + overflow
        with self.assertRaises(rec.Incomplete):
            rec.capture(sd, dev, 1, sleep=lambda s: None)
        self.assertEqual(rec.capture(FakeSd(), dev, 1, sleep=lambda s: None).shape, (16000, 2))   # selfcheck: a good stream passes
        # the whole run: open #1 = the sound check (good), #2 = clip 1 cut short, #3 = clip 1 again (good), then q at clip 2
        writes = []
        real = sf.write

        def counting(*a, **k):
            writes.append(a[0])
            return real(*a, **k)
        sd = FakeSd(supply=lambda n, rate: 10 * rate if n != 2 else 3 * rate)
        with mock.patch.object(sf, "write", counting):
            code, text = quiet_run(self.out_dir, False, 11, input_fn=self.answers(["y", "", "", "", "", "q"]), sd=sd)
        self.assertEqual(code, 0)
        self.assertEqual(text.count("녹음이 끊겼어요 — 다시 녹음"), 1)
        self.assertEqual(len(writes), 1)   # only the good take was written
        m = json.load(open(os.path.join(self.out_dir, "manifest.json"), encoding="utf-8"))
        self.assertEqual([c["clip"] for c in m["clips"]], ["s8_u01_clean"])
        self.assertEqual(sorted(os.listdir(os.path.join(self.out_dir, "clips"))), ["s8_u01_clean.wav"])
        self.assertEqual(sd.opened, 3)
        self.assertEqual(sd.closed, 3)
        # the same with an overflow flag instead of a short stream: the clip is asked again, nothing saved for it
        d2 = self.out_dir + "_flag"
        sd = FakeSd(flag_block=lambda n, b: n == 2 and b == 5)
        with mock.patch.object(sf, "write", counting):
            writes.clear()
            code, text = quiet_run(d2, False, 11, input_fn=self.answers(["y", "", "", "q"]), sd=sd)   # the take is refused, then q
        self.assertEqual((code, writes, text.count("녹음이 끊겼어요 — 다시 녹음")), (0, [], 1))
        self.assertFalse(os.path.exists(d2))
        # a cut sound check is shown as cut (not as "quiet"), nothing is saved, and the check is asked again
        d3 = self.out_dir + "_check"
        sd = FakeSd(supply=lambda n, rate: 10 * rate if n != 1 else 2 * rate)
        with mock.patch.object(sf, "write", counting):
            code, text = quiet_run(d3, False, 11, input_fn=self.answers(["y", "", "", "q"]), sd=sd)   # pick, "check again", q
        self.assertEqual(code, 0)
        self.assertIn("소리 확인이 끊겼어요", text)
        self.assertEqual(writes, [])
        self.assertEqual((sd.opened, sd.closed), (2, 2))

    def test_clipping_is_checked_per_input_channel_before_the_average(self):
        import numpy as np
        import soundfile as sf

        def two(left, right):
            def f(frames, rate, channels, device):
                t = np.arange(frames) / float(rate)
                s = np.sin(2 * math.pi * 500 * t).astype("float32")
                return np.stack([np.clip(left * s, -1, 1), np.clip(right * s, -1, 1)], axis=1).astype("float32")
            return f
        # a clipped left channel (+-1) with a quiet right one: the average would hide it (peak 0.7 after averaging), the warning must not
        for name, sig, want in (("avg_hides", two(3.0, 0.4), True), ("silent_other", two(3.0, 0.0), True), ("fine", two(0.5, 0.4), False),
                                ("right_only", two(0.4, 3.0), True)):
            sd = FakeSd(signal=sig)
            d = os.path.join(TMP, "recdev_clip_%s" % name)
            code, text = quiet_run(d, False, 11, input_fn=self.answers(["y", "", "", "q"]), sd=sd, device="8")
            self.assertEqual(code, 0, name)
            self.assertEqual("잘렸어요" in text, want, name)
            if name == "avg_hides":
                data, _ = sf.read(os.path.join(d, "clips", "s8_u01_clean.wav"), dtype="int16")
                self.assertLess(float(np.abs(data).max()) / 32767.0, 0.99)   # the saved clip itself looks fine: only the channel check sees it
        # the converted samples are checked too (a full scale tone that overshoots when resampled is saturated)
        x = np.sign(np.sin(np.linspace(0, 100 * math.pi, 48000))).astype("float32") * 0.995
        out = []
        rec.take_report(rec.to_int16(rec.to_16k(x, 48000)), out.append)
        self.assertTrue(any("잘렸어요" in l for l in out))
        # mixdown reports the input channel peak itself
        self.assertTrue(rec.mixdown(np.stack([x, x * 0.0], axis=1))[1])
        self.assertFalse(rec.mixdown(np.stack([x * 0.5, x * 0.4], axis=1))[1])

    def test_device_numbers_are_ascii_digits_only(self):
        for text, ok in (("2", True), ("0012", True), ("9999", True), ("12345", False), ("", False), ("\u00b2", False), ("\u0662", False),
                         ("\uff12", False), ("1" * 5000, False), ("2\n", False), ("-1", False), ("2.0", False), ("0x2", False)):
            self.assertEqual(rec.is_number(text), ok, repr(text[:10]))
        devs = rec.list_input_devices(FakeSd())
        for odd in ("\u00b2", "\u0662", "\uff12", "1" * 5000, "9" * 5000, "2\n²", "\x00", "-1"):
            with self.assertRaises(rec.RecError) as cm:   # --device: never another kind of exception
                rec.resolve_device(devs, odd)
            self.assertEqual(str(cm.exception), "device")
            sd = FakeSd()   # the list: asked again, then the real answer is taken
            code, text = quiet_run(self.out_dir, False, 11, input_fn=self.answers(["y", odd, "8", "q"]), sd=sd)
            self.assertEqual((code, {c["device"] for c in sd.calls}), (0, {8}), repr(odd[:5]))
            self.assertIn("목록에 없는 번호예요", text)
            sd = FakeSd()
            with self.assertRaises(rec.RecError):
                quiet_run(self.out_dir, False, 11, input_fn=self.answers(["y"]), sd=sd, device=odd)
            self.assertEqual(sd.calls, [])
        # a name that contains such a character still works as a part of a name
        self.assertEqual(rec.resolve_device([dict(devs[0], name="Mic\u00b2 pro")], "\u00b2")["name"], "Mic\u00b2 pro")

    def test_quiet_and_clipped_clips_get_a_warning_and_the_size_is_shown(self):
        import numpy as np
        tone = lambda amp: (amp * np.sin(np.linspace(0, 400 * math.pi, 16000 * 6)) * 32767).astype(np.int16)
        loud = (np.sign(np.sin(np.linspace(0, 200 * math.pi, 16000 * 6))) * 32767).astype(np.int16)   # square wave at full scale
        cases = {"quiet": (tone(0.001), True, False), "faint": (tone(0.015), True, False),   # rms .0106 but peak < 0.02: still quiet
                 "ok": (tone(0.3), False, False), "clipped": (loud, False, True)}
        for name, (samples, want_quiet, want_clip) in cases.items():
            d = os.path.join(TMP, "recdev_w_%s" % name)
            code, text = quiet_run(d, False, 11, input_fn=self.answers(["y", "", "", "q"]), recorder=lambda *_: samples)
            self.assertEqual(code, 0)
            self.assertEqual("너무 작아요" in text, want_quiet, name)
            self.assertEqual("잘렸어요" in text, want_clip, name)
            self.assertEqual("r 로 다시 녹음" in text, want_quiet or want_clip, name)
            self.assertRegex(text, r"\[#*\.*\] 크기 rms \d\.\d{4}, peak \d\.\d{3}")
            self.assertEqual(len(json.load(open(os.path.join(d, "manifest.json"), encoding="utf-8"))["clips"]), 1)   # a warning is not forced
        self.assertTrue(rec.too_quiet(0.002, 0.5))
        self.assertTrue(rec.too_quiet(0.05, 0.01))
        self.assertFalse(rec.too_quiet(0.01, 0.1))

    def test_sound_check_is_shown_but_never_written(self):
        import soundfile as sf
        writes = []
        real = sf.write

        def counting(*a, **k):
            writes.append(a[0])
            return real(*a, **k)
        sd = FakeSd()
        with mock.patch.object(sf, "write", counting):
            # the check passes, then 'q' at the first clip: the only audio so far is the check -> no file, no folder
            code, text = quiet_run(self.out_dir, False, 11, input_fn=self.answers(["y", "", "q"]), sd=sd)
            self.assertEqual(code, 0)
            self.assertEqual(writes, [])
            self.assertFalse(os.path.exists(self.out_dir))
            self.assertEqual((sd.calls[0]["kind"], sd.calls[0]["rate"], sd.calls[0]["device"]), ("InputStream", 44100, 2))
            self.assertIn("소리 확인", text)
            self.assertIn("저장하지 않아요", text)
            self.assertRegex(text, r"\[#+\.*\] 크기 rms \d\.\d{4}, peak \d\.\d{3}")
            # check + one clip: exactly one file is written (the clip) and the manifest
            writes.clear()
            code, text = quiet_run(self.out_dir, False, 11, input_fn=self.answers(["y", "", "", "", "q"]), sd=sd)
            self.assertEqual(len(writes), 1)
            self.assertTrue(writes[0].endswith("s8_u01_clean.wav"))
            self.assertEqual(sorted(os.listdir(os.path.join(self.out_dir, "clips"))), ["s8_u01_clean.wav"])
            self.assertEqual(sorted(os.listdir(self.out_dir)), ["clips", "manifest.json"])

    def test_quiet_sound_check_offers_another_device_a_new_check_or_going_on(self):
        quiet_map = {2: 0.0005, 6: 0.0005}   # the ZOOM entries are silent in this test, the others loud
        sd = FakeSd(signal=sine_signal(per_device=quiet_map, amp=0.4))
        # d = choose again (a loud device), then the clip stage starts on it
        code, text = quiet_run(self.out_dir, False, 11, input_fn=self.answers(["y", "", "d", "8", "q"]), sd=sd)
        self.assertEqual(code, 0)
        self.assertIn("소리가 거의 안 들려요", text)
        self.assertEqual([c["device"] for c in sd.calls], [2, 8])
        # r = check again on the same device (an unknown answer is asked again), then Enter = go on anyway
        sd = FakeSd(signal=sine_signal(per_device=quiet_map, amp=0.4))
        code, text = quiet_run(self.out_dir + "_b", False, 11, input_fn=self.answers(["y", "", "r", "zzz", "", "", "", "q"]), sd=sd)
        self.assertEqual([c["device"] for c in sd.calls[:2]], [2, 2])
        self.assertEqual(text.count("소리가 거의 안 들려요"), 2)
        self.assertEqual(len(sd.calls), 3)   # the check twice, then the first clip on the quiet device
        self.assertTrue(all(c["device"] == 2 for c in sd.calls))
        # a loud device gets no question at all
        sd = FakeSd()
        code, text = quiet_run(self.out_dir + "_c", False, 11, input_fn=self.answers(["y", "", "q"]), sd=sd)
        self.assertNotIn("소리가 거의 안 들려요", text)

    def test_readme_has_no_control_characters_and_its_commands_run(self):
        path = os.path.join(ROOT, "phone_src", "calib", "README.txt")
        raw = open(path, "rb").read()
        bad = [(i, hex(c)) for i, c in enumerate(raw) if c < 32 and c not in (10, 13)]   # 0x07 \a, 0x09 \t, 0x0b \v ... all of them
        self.assertEqual(bad, [])
        self.assertIn(b"docs\\v201_design.md", raw)
        # selfcheck: the scan sees a tab and a bell
        self.assertEqual(len([c for c in b"a\tb\x07" if c < 32 and c not in (10, 13)]), 2)
        text = raw.decode("utf-8")
        cmds = [l.strip() for l in text.splitlines() if re.match(r"^\s+& \$PY .*calib_record\.py", l)]
        self.assertEqual(len(cmds), 3)   # list, record, record with --device 2
        self.assertEqual([("--device 2" in c, "--list-devices" in c) for c in cmds], [(False, True), (False, False), (True, False)])
        for c in cmds:
            for ch in "<>[]":
                self.assertNotIn(ch, c)   # no placeholders
            m = re.search(r'"\$W\\([^"]+)"', c)
            self.assertIsNotNone(m, c)
            self.assertTrue(os.path.isfile(os.path.join(ROOT, m.group(1))), m.group(1))   # the tool path is a real file
            self.assertEqual(m.group(1), "phone_src\\tools\\calib_record.py")
            self.assertIn('-I -X utf8', c)
        outs = [re.search(r'--out "\$T\\([^"]+)"', c) for c in cmds[1:]]
        self.assertTrue(all(outs))
        # the first command a user pastes really runs (the list; nothing is opened)
        r = subprocess.run([sys.executable, "-I", "-X", "utf8", os.path.join(ROOT, "phone_src", "tools", "calib_record.py"), "--help"],
                           capture_output=True)
        self.assertEqual(r.returncode, 0)
        for need in (b"$PY = ", b"$W  = ", b"$T  = "):
            self.assertIn(need, raw)

    def test_cli_options_and_source_rules(self):
        py = [sys.executable, "-I", "-X", "utf8", os.path.join(HERE, "calib_record.py")]
        r = subprocess.run(py + ["--dry-run"], capture_output=True)
        self.assertEqual(r.returncode, 2)   # --out is still required without --list-devices
        r = subprocess.run(py + ["--help"], capture_output=True, text=True, encoding="utf-8")
        for opt in ("--list-devices", "--device", "--out", "--dry-run"):
            self.assertIn(opt, r.stdout)
        src = open(os.path.join(HERE, "calib_record.py"), encoding="utf-8").read()
        self.assertEqual(len(re.findall(r"logging|\.log", src)), 0)
        self.assertNotIn("sd.rec(", src)   # a stream with a callback: the frames that really arrive are counted
        self.assertIn("sd.InputStream(", src)
        self.assertNotIn("urllib", src)


# ================================================================================================ FXA (v2.0.2): clip id prefix of a recording session
def good_recorder(*_a):
    import numpy as np
    return (np.sin(np.linspace(0, 400 * math.pi, 16000 * 6)) * 0.3 * 32767).astype(np.int16)


def record_session(out_dir, tag, sentences=2):
    """a whole fake session (no microphone): `sentences` sentences = 2 x sentences clips, then q. -> (code, manifest or None)"""
    answers = ["y"] + ["", ""] * (2 * sentences) + ["q"]
    it = iter(answers)
    code, text = quiet_run(out_dir, False, 11, input_fn=lambda *_: next(it), recorder=good_recorder, set_tag=tag)
    mp = os.path.join(out_dir, "manifest.json")
    return code, (json.load(open(mp, encoding="utf-8")) if os.path.exists(mp) else None)


class SetTags(unittest.TestCase):
    BAD_TAGS = ("", "A1", "1a", "a b", "a" * 13, "../x", "s-8", "s8\n", " s8", "S8", "éa", "a_b", "s8.", "١a")

    def setUp(self):
        self.out_dir = os.path.join(TMP, "settag_%d" % random.randrange(10 ** 9))

    def test_tag_rule_accepts_the_good_ones_and_refuses_the_bad_ones(self):
        for good in ("s8", "a", "s1127193000", "abc123", "a" * 12, "z0"):
            self.assertEqual(rec.resolve_set_tag(good), good)
        for bad in self.BAD_TAGS:
            with self.assertRaises(rec.SetTagRefused, msg=repr(bad)):
                rec.resolve_set_tag(bad)
        for odd in (5, b"s8", ["s8"]):
            with self.assertRaises(rec.SetTagRefused):
                rec.resolve_set_tag(odd)
        # selfcheck: the rule really is the one that refuses (a pattern that accepts everything would let the table through)
        self.assertIsNone(rec.SET_TAG_RE.fullmatch("A1"))
        self.assertIsNotNone(rec.SET_TAG_RE.fullmatch("s8"))

    def test_every_clip_id_starts_with_the_tag_and_the_manifest_names_the_set(self):
        code, m = record_session(self.out_dir, "s8")
        self.assertEqual(code, 0)
        ids = [c["clip"] for c in m["clips"]]
        self.assertEqual(len(ids), 4)
        self.assertTrue(all(i.startswith("s8_u") for i in ids), ids)
        self.assertEqual(ids, ["s8_u01_clean", "s8_u01_wrong", "s8_u02_clean", "s8_u02_wrong"])
        self.assertEqual(m["set"], "s8")
        self.assertEqual([c["file"] for c in m["clips"]], ["clips/%s.wav" % i for i in ids])
        self.assertEqual(sorted(os.listdir(os.path.join(self.out_dir, "clips"))), sorted(i + ".wav" for i in ids))
        # selfcheck: a clip id without the prefix is not what the check above looks for
        self.assertFalse("u01_clean".startswith("s8_u"))

    def test_two_sessions_with_different_tags_share_no_id_and_the_same_tag_does(self):
        _c, a = record_session(self.out_dir + "_a", "a1")
        _c, b = record_session(self.out_dir + "_b", "b2")
        ids_a, ids_b = {c["clip"] for c in a["clips"]}, {c["clip"] for c in b["clips"]}
        self.assertEqual(len(ids_a), 4)
        self.assertEqual(ids_a & ids_b, set())
        self.assertEqual((a["set"], b["set"]), ("a1", "b2"))
        # selfcheck: the same tag twice does overlap, so the empty intersection above means something
        _c, c = record_session(self.out_dir + "_c", "a1")
        self.assertEqual(ids_a & {x["clip"] for x in c["clips"]}, ids_a)

    def test_without_a_tag_the_automatic_one_matches_the_rule(self):
        self.assertEqual(rec.resolve_set_tag(None, now=datetime.datetime(2026, 11, 27, 19, 30, 5)), "s1127193005")
        code, m = record_session(self.out_dir, None)
        self.assertEqual(code, 0)
        self.assertRegex(m["set"], rec.SET_TAG_RE.pattern)
        self.assertRegex(m["set"], r"^s\d{10}$")
        self.assertTrue(all(c["clip"].startswith(m["set"] + "_u") for c in m["clips"]))

    def test_wrong_tags_fail_with_set_tag_and_exit_2_and_touch_nothing(self):
        sd_calls = []
        for bad in self.BAD_TAGS:
            for dry in (False, True):
                out = os.path.join(TMP, "settag_bad_%d" % random.randrange(10 ** 9))
                argv = ["--out", out, "--set-tag", bad] + (["--dry-run"] if dry else [])
                buf = io.StringIO()
                with contextlib.redirect_stdout(buf), mock.patch.object(rec, "load_sd", lambda: sd_calls.append(1)), \
                        mock.patch("builtins.input", lambda *_: self.fail("asked")):
                    code = rec.main(argv)
                self.assertEqual((code, buf.getvalue().strip()), (2, "CALIB_REC_FAIL set_tag"), (bad, dry))
                self.assertFalse(os.path.exists(out), (bad, dry))   # no folder, no manifest
        self.assertEqual(sd_calls, [])   # the microphone module was never loaded
        # selfcheck: a good tag does not fail the same way
        out = os.path.join(TMP, "settag_good_%d" % random.randrange(10 ** 9))
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            code = rec.main(["--out", out, "--set-tag", "s8", "--dry-run"])
        self.assertEqual(code, 0)
        self.assertNotIn("set_tag", buf.getvalue())

    def test_the_command_line_refuses_a_wrong_tag_and_the_dry_run_ends_with_the_tag(self):
        py = [sys.executable, "-I", "-X", "utf8", os.path.join(HERE, "calib_record.py")]
        out = os.path.join(TMP, "settag_cli_%d" % random.randrange(10 ** 9))
        r = subprocess.run(py + ["--out", out, "--dry-run", "--set-tag", "A1"], capture_output=True, text=True, encoding="utf-8")
        self.assertEqual((r.returncode, r.stdout.strip()), (2, "CALIB_REC_FAIL set_tag"))
        self.assertFalse(os.path.exists(out))
        r = subprocess.run(py + ["--out", out, "--dry-run", "--set-tag", "s8"], capture_output=True, text=True, encoding="utf-8")
        self.assertEqual(r.returncode, 0)
        last = r.stdout.strip().splitlines()[-1]
        self.assertEqual(last, "CALIB_REC_DRY_RUN sentences=30 clips=60 (no microphone opened, nothing written) set=s8")
        self.assertFalse(os.path.exists(out))
        # no tag: the automatic one is on the last line
        r = subprocess.run(py + ["--out", out, "--dry-run"], capture_output=True, text=True, encoding="utf-8")
        self.assertRegex(r.stdout.strip().splitlines()[-1], r"nothing written\) set=s\d{10}$")
        # the consent text is the one of before
        self.assertIn(rec.CONSENT_TEXT, r.stdout)

    def test_calib_fit_takes_two_sets_recorded_in_two_sessions(self):
        pc, ph = FIX["good"]
        user = [i for i, c in enumerate(pc["clips"]) if c["group"] == "user"]
        self.assertEqual(len(user), 24)
        half = len(user) // 2

        def build(tag_a, tag_b):
            _c, a = record_session(os.path.join(TMP, "fit_a_%s_%s" % (tag_a, tag_b)), tag_a, sentences=6)
            _c, b = record_session(os.path.join(TMP, "fit_b_%s_%s" % (tag_a, tag_b)), tag_b, sentences=6)
            ids_a, ids_b = [c["clip"] for c in a["clips"]], [c["clip"] for c in b["clips"]]
            self.assertEqual((len(ids_a), len(ids_b)), (half, half))
            new = {}
            for idx, cid in zip(user[:half], ids_a):
                new[pc["clips"][idx]["id"]] = cid
            for idx, cid in zip(user[half:], ids_b):
                new[pc["clips"][idx]["id"]] = cid
            files = {}
            for kind, doc in (("pc", pc), ("phone", ph)):
                clips = [dict(c, id=new.get(c["id"], c["id"])) for c in doc["clips"]]
                synth = [c for c in clips if c["id"] not in new.values()]
                set_a = [c for c in clips if c["id"] in ids_a]
                set_b = [c for c in clips if c["id"] in ids_b]
                name = "two_%s_%s_%s" % (kind, tag_a, tag_b)
                files[kind] = [dump(dict(doc, clips=synth + set_a), name + "_1.json"), dump(dict(doc, clips=set_b), name + "_2.json")]
            params = os.path.join(TMP, "two_%s_%s_params.json" % (tag_a, tag_b))
            report = os.path.join(TMP, "two_%s_%s_report.json" % (tag_a, tag_b))
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                code = cf.main(["--pc"] + files["pc"] + ["--phone"] + files["phone"] + ["--out-params", params, "--report", report])
            return code, buf.getvalue(), params

        code, out, params = build("s8", "s9")   # different tags: the two files join, every clip is used
        self.assertEqual(code, 0, out)
        self.assertIn("CALIB_OK", out)
        self.assertTrue(os.path.exists(params))
        code, out, params = build("s8", "s8")   # selfcheck: the same tag in both sessions = the same ids = refused
        self.assertEqual(code, 1)
        self.assertIn("CALIB_FAIL input", out)
        self.assertFalse(os.path.exists(params))

    def test_a_wrong_tag_is_refused_before_any_device_is_listed(self):
        listed, sd_loaded = [], []
        for extra in (["--list-devices"], ["--list-devices", "--dry-run"], ["--dry-run"], []):
            for bad in ("A1", "", "a b", "a" * 13):
                buf = io.StringIO()
                with contextlib.redirect_stdout(buf), mock.patch.object(rec, "list_devices", lambda *a, **k: listed.append(1) or 0), \
                        mock.patch.object(rec, "load_sd", lambda: sd_loaded.append(1)):
                    code = rec.main(["--set-tag", bad] + extra)
                self.assertEqual((code, buf.getvalue().strip()), (2, "CALIB_REC_FAIL set_tag"), (bad, extra))
        self.assertEqual((listed, sd_loaded), ([], []))   # no device enumeration, no microphone module
        # selfcheck: a good tag with --list-devices does reach the enumeration (the counter is not blind)
        with contextlib.redirect_stdout(io.StringIO()), mock.patch.object(rec, "list_devices", lambda *a, **k: listed.append(1) or 0):
            self.assertEqual(rec.main(["--list-devices", "--set-tag", "s8"]), 0)
        self.assertEqual(listed, [1])
        # and from the command line (the real entry point): the tag is checked first, so no device is listed
        py = [sys.executable, "-I", "-X", "utf8", os.path.join(HERE, "calib_record.py")]
        r = subprocess.run(py + ["--list-devices", "--set-tag", "A1"], capture_output=True, text=True, encoding="utf-8")
        self.assertEqual((r.returncode, r.stdout.strip()), (2, "CALIB_REC_FAIL set_tag"))

    def test_two_sessions_in_the_same_minute_get_different_automatic_tags(self):
        orig = rec.resolve_set_tag
        sets = []
        for sec in (0, 59):
            moment = datetime.datetime(2026, 11, 27, 19, 30, sec)
            with mock.patch.object(rec, "resolve_set_tag", side_effect=lambda tag, m=moment: orig(tag, now=m)):
                _c, m = record_session(self.out_dir + "_auto%d" % sec, None)
            sets.append(m)
        self.assertNotEqual(sets[0]["set"], sets[1]["set"])
        self.assertEqual({c["clip"] for c in sets[0]["clips"]} & {c["clip"] for c in sets[1]["clips"]}, set())
        for m in sets:
            self.assertRegex(m["set"], rec.SET_TAG_RE.pattern)

    def two_session_rows(self, tags, scores, same_seed=True):
        """(pc, phone) rows of two fake recording sessions made with the same seed (the same sentences): the pc side carries the
        controlled score of each clip; the phone side is the same score (phone_result is replaced below)"""
        sessions = []
        for k, tag in enumerate(tags):
            _c, m = record_session(os.path.join(TMP, "pair_%d_%s_%d" % (random.randrange(10 ** 9), tag, k)), tag, sentences=2)
            sessions.append(m)
        if same_seed:
            self.assertEqual([c["sentence_id"] for c in sessions[0]["clips"]], [c["sentence_id"] for c in sessions[1]["clips"]])
        rows = []
        for session, vals in zip(sessions, scores):
            for c, val in zip(session["clips"], vals):
                sc = {"units": [], "score": val, "fluency": 0}
                pc = {"id": c["clip"], "sentence_id": c["sentence_id"], "variant": c["variant"], "voice": c["voice"], "group": "user",
                      "target": c["target"], "score": sc}
                rows.append((pc, sc))
        return rows

    def test_the_same_sentence_in_two_sessions_keeps_every_pair(self):
        # per session: sentence 1 (clean, wrong) then sentence 2 (clean, wrong). Session A: wrong lower for sentence 1 only,
        # session B: wrong lower for sentence 2 only -> 4 pairs, exactly 2 of them have the wrong clip lower
        a, b = (80, 60, 70, 90), (60, 80, 90, 70)
        rows = self.two_session_rows(("run1", "run2"), (a, b))
        with mock.patch.object(cf, "phone_result", side_effect=lambda _s, _pc, ph, *_: ph):
            one = cf.evaluate(None, rows[:4], None, None)
            two = cf.evaluate(None, rows[4:], None, None)
            both = cf.evaluate(None, rows, None, None)
            swapped = cf.evaluate(None, rows[4:] + rows[:4], None, None)
        self.assertEqual((one["pair_count"], two["pair_count"]), (2, 2))
        self.assertEqual((both["pair_count"], both["clips"]), (4, 8))   # nothing is overwritten
        self.assertEqual((swapped["pair_count"], swapped["wrong_lower_pairs"]), (4, both["wrong_lower_pairs"]))   # the order does not matter
        self.assertAlmostEqual(both["wrong_lower_pairs"], (one["wrong_lower_pairs"] * 2 + two["wrong_lower_pairs"] * 2) / 4.0)
        self.assertAlmostEqual(both["wrong_lower_pairs"], 0.5)
        # selfcheck: without the set in the key the same rows collapse to 2 pairs (the key the review reproduced)
        flat = [(dict(pc, id="x%d" % n), ph) for n, (pc, ph) in enumerate(rows)]
        with mock.patch.object(cf, "phone_result", side_effect=lambda _s, _pc, ph, *_: ph):
            self.assertEqual(cf.evaluate(None, flat, None, None)["pair_count"], 2)

    def test_clip_set_comes_from_the_set_field_or_the_clip_id_tag(self):
        self.assertEqual(cf.clip_set({"id": "s8_u01_clean"}), "s8")
        self.assertEqual(cf.clip_set({"id": "run2_u12_wrong"}), "run2")
        self.assertEqual(cf.clip_set({"id": "u01_clean"}), "")   # the old untagged recordings
        self.assertEqual(cf.clip_set({"id": "c10131872_af_heart_clean"}), "")   # synthetic clips
        self.assertEqual(cf.clip_set({"id": "u01_clean", "set": "b2"}), "b2")
        self.assertEqual(cf.clip_set({"id": "A1_u01_clean"}), "")   # not a valid tag: not a set
        self.assertEqual(cf.clip_set({}), "")

    def test_the_same_sentence_of_two_sessions_stays_in_one_split_group(self):
        rows = self.two_session_rows(("run1", "run2"), ((80, 60, 70, 90), (60, 80, 90, 70)))
        # more sentences so a split is possible; the two sessions share their sentences
        extra = [({"id": "x%d_af_clean" % n, "sentence_id": "x%d" % n, "variant": "clean", "voice": "af", "group": "synth",
                   "target": "extra sentence number %s here" % "abcdefgh"[n], "score": {"units": [], "score": 70, "fluency": 0}}, {}) for n in range(8)]
        for seed in range(1, 12):
            train, held = cf.split_sentences(rows + extra, seed=seed, S=S)
            ids_train = {pc["id"] for pc, _ in train}
            ids_held = {pc["id"] for pc, _ in held}
            for sid in {pc["sentence_id"] for pc, _ in rows}:
                sides = {("train" if pc["id"] in ids_train else "held") for pc, _ in rows if pc["sentence_id"] == sid}
                self.assertEqual(len(sides), 1, (seed, sid))   # both sessions of one sentence on one side
            self.assertEqual(ids_train & ids_held, set())

    def test_readme_tells_how_to_record_in_two_sessions(self):
        text = open(os.path.join(ROOT, "phone_src", "calib", "README.txt"), encoding="utf-8").read()
        self.assertIn("--set-tag", text)
        self.assertIn("두 번", text)
        self.assertIn("--seed 12", text)   # two sessions read different sentences
        self.assertIn("월일시분초", text)
        # selfcheck: the same scan on text without it finds nothing
        self.assertNotIn("--set-tag", "calib_record.py --out x")


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
