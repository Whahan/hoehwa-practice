# -*- coding: utf-8 -*-
"""PA2 tests (docs/v201_design.md 5.2): phone_src\\tools\\make_score_golden.py and godot\\tests\\fixtures\\score_golden_en.json.

  <repo>\\..\\app\\backend\\.venv\\Scripts\\python.exe -I -X utf8 -m unittest discover -s phone_src\\tools -p test_make_score_golden.py

Covers: PA2-1 (this file), PA2-2 (--check is clean and says SCORE_GOLDEN_OK), the counts (>= 120 cases, >= 10 with another ok_prob,
>= 300 alignments, >= 380 en_words inputs), no socket / process while generating, backend\\ untouched (sha256 of every .py and the
list of files), and DRIFT: a changed value, a missing file, broken JSON, a changed table and a changed server rule must all be
reported (the "selfcheck" tests feed the checker a wrong input and expect it to say so). Writes only under a temp folder.
"""
import contextlib
import copy
import hashlib
import io
import json
import os
import shutil
import socket
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True   # nothing is written next to the sources (no __pycache__ under phone_src or backend)

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)
import make_score_golden as G   # noqa: E402

ROOT = G.ROOT
BACKEND = G.BACKEND


def backend_state():
    """{relative path: sha256 or '<dir>'} of everything under backend\\ except the virtual environment"""
    out = {}
    for dp, dn, fn in os.walk(BACKEND):
        dn[:] = [d for d in dn if d != ".venv"]
        for d in dn:
            out[os.path.relpath(os.path.join(dp, d), BACKEND)] = "<dir>"
        for f in fn:
            p = os.path.join(dp, f)
            with open(p, "rb") as fh:
                out[os.path.relpath(p, BACKEND)] = hashlib.sha256(fh.read()).hexdigest()
    return out


class ScoreGoldenTests(unittest.TestCase):
    doc = None
    before = None

    @classmethod
    def setUpClass(cls):
        cls.before = backend_state()
        cls.tmp = tempfile.mkdtemp(prefix="hoehwa_test_scoregolden_")
        with G.no_network():
            cls.doc = G.build()
            cls.S = G.load_server()

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def tmp_file(self, name, text):
        p = os.path.join(self.tmp, name)
        with open(p, "w", encoding="utf-8", newline="\n") as f:
            f.write(text)
        return p

    # ---- the data
    def test_01_counts(self):
        d = self.doc
        self.assertGreaterEqual(len(d["cases"]), 120)
        self.assertGreaterEqual(sum(1 for c in d["cases"] if c.get("ok_prob", 0.45) != 0.45), 10)
        self.assertGreaterEqual(len(d["align"]), 300)
        self.assertGreaterEqual(len(d["en_words"]), 380)
        self.assertIsInstance(d["known_gaps"], list)
        ids = [c["id"] for c in d["cases"]]
        self.assertEqual(len(ids), len(set(ids)), "case ids are unique")
        self.assertEqual(d["v"], 1)
        self.assertEqual(d["ok_prob"], self.S.OK_PROB)

    def test_02_cases_are_the_server_results(self):
        S = self.S
        for c in self.doc["cases"]:
            res, err = G.run_case(S, c["target"], c["words"], c["text"], c.get("ok_prob"))
            self.assertEqual(res, c["expect"], c["id"])
            self.assertEqual(list(res.keys()), list(c["expect"].keys()), "key order " + c["id"])
            self.assertEqual(err, c.get("error"))

    def test_03_result_shape(self):
        for c in self.doc["cases"]:
            e = c["expect"]
            if not e:
                self.assertEqual(c.get("error"), G.EMPTY_TARGET_MSG, c["id"])
                continue
            self.assertEqual(list(e.keys()), ["transcript", "score", "accuracy", "clarity", "fluency", "units", "tips_ko"], c["id"])
            for u in e["units"]:
                self.assertEqual(list(u.keys()), ["t", "ok", "conf", "heard"], c["id"])
                self.assertTrue(0.0 <= u["conf"] <= 1.0)
            for k in ("score", "accuracy", "clarity", "fluency"):
                self.assertIsInstance(e[k], int)
                self.assertTrue(0 <= e[k] <= 100)
            self.assertLessEqual(len(e["tips_ko"]), 3)

    def test_04_every_kind_of_tip_is_covered(self):
        tips = " ".join(t for c in self.doc["cases"] for t in c["expect"].get("tips_ko", []))
        for key in ("r은 혀끝", "f는 윗니", "v는 윗니", "th는 혀끝", "z는 혀를", "짧은 i", "긴 ee", "짧은 u", "긴 oo", "a와 e", "e와 a", "복수형 s", "-ed(d/t)",
                    "받침처럼", "놓치거나", "그 단어만", "속도나 멈춤", "목표 문장과", "목소리가"):
            self.assertIn(key, tips)
        rules = set()
        for c in self.doc["cases"]:
            for u in c["expect"].get("units", []):
                if u["heard"]:
                    rules.add((u["t"], u["heard"]))
        self.assertGreaterEqual(len(rules), 20)

    def test_05_words_look_like_a_recogniser(self):
        """the golden inputs must be inputs ScoreCore leaves alone: p in [0, 1], time stamps never going back"""
        for c in self.doc["cases"]:
            prev = 0.0
            for w in c["words"]:
                self.assertTrue(0.0 <= w["p"] <= 1.0, c["id"])
                self.assertGreaterEqual(w["start"], prev - 1e-9, c["id"])
                self.assertGreaterEqual(w["end"], w["start"], c["id"])
                prev = w["start"]

    def test_06_numbers_and_hard_inputs(self):
        ins = {e["in"]: e["out"] for e in self.doc["en_words"]}
        for n in range(100):
            self.assertIn(str(n), ins)
        self.assertEqual(ins["21"], ["twenty", "one"])
        self.assertEqual(ins["101"], ["one", "hundred", "and", "one"])
        self.assertEqual(ins["1234567890"], ["1234567890"])
        for needle in ("1,234", "\u2019", "\u2014", "\u00a0", "\uff28", "\ufb01", "cafe\u0301", "\u0130stanbul"):
            self.assertTrue(any(needle in k for k in ins), needle)
        self.assertGreaterEqual(sum(1 for e in self.doc["en_words"] if e["in"] in G.HARD_INPUTS), 80)

    def test_07_alignments(self):
        for e in self.doc["align"]:
            pairs, inserts = self.S.align_seq(e["a"], e["b"], self.S.word_sim)
            self.assertEqual(e["pairs"], [[j, bool(x)] for j, x in pairs])
            self.assertEqual(e["inserts"], [[i, j] for i, j in inserts])
            self.assertEqual(len(e["pairs"]), len(e["a"]))
            self.assertEqual(e["sim"], [self.S.word_sim(e["a"][k], e["b"][k]) for k in range(min(len(e["a"]), len(e["b"])))])
        self.assertGreaterEqual(sum(len(e["sim"]) for e in self.doc["align"]), 400)
        self.assertTrue(any(len(x) >= 200 for e in self.doc["align"] for x in e["a"] + e["b"]), "tokens of 200+ characters (autojunk)")

    def test_08b_unicode_cases_present(self):
        ids = {c["id"] for c in self.doc["cases"]}
        for needed in ("unicode_marks_reordered", "unicode_marks_blocked", "unicode_digit_group", "unicode_armenian_stop", "unicode_greek_question"):
            self.assertIn(needed, ids)
        ins = {e["in"] for e in self.doc["en_words"]}
        for needle in ("CAFE\u0315\u0301", "1,2\u06634", "1,234\u0589", "1,234\u037e"):
            self.assertIn(needle, ins)
        self.assertGreaterEqual(len(ins), 700)
        by_id = {c["id"]: c for c in self.doc["cases"]}
        r = by_id["unicode_marks_reordered"]["expect"]
        self.assertEqual([u["t"] for u in r["units"]], ["caf"])
        self.assertEqual(r["score"], 15)

    def test_08_rounding_cases_present(self):
        confs = {u["conf"] for c in self.doc["cases"] if c["id"].startswith("round_") for u in c["expect"]["units"]}
        for v in (0.062, 0.188, 0.312, 0.438, 0.123, 1.0):
            self.assertIn(v, confs)

    def test_09_known_gaps_have_reasons_and_server_output(self):
        for g in self.doc["known_gaps"]:
            self.assertGreater(len(g["why"]), 20)
            self.assertEqual(g["out"], self.S.en_words(g["in"]))

    # ---- no side effects
    def test_10_no_socket_and_no_process_while_generating(self):
        """inside the guard every attempt raises (no socket, no lookup, no process is made); afterwards the very same objects are
        back, which is checked by identity: this test makes no socket"""
        import subprocess
        orig = (socket.socket.__init__, socket.getaddrinfo, socket.create_connection, subprocess.Popen.__init__)
        with G.no_network():
            inside = (socket.socket.__init__, socket.getaddrinfo, socket.create_connection, subprocess.Popen.__init__)
            for o, i in zip(orig, inside):
                self.assertIsNot(o, i, "the guard replaced the member")
            with self.assertRaises(G.NetworkBlocked):
                socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            with self.assertRaises(G.NetworkBlocked):
                socket.getaddrinfo("localhost", 80)
            with self.assertRaises(G.NetworkBlocked):
                socket.create_connection(("localhost", 80))
            with self.assertRaises(G.NetworkBlocked):
                subprocess.Popen(["cmd", "/c", "echo", "x"])
        after = (socket.socket.__init__, socket.getaddrinfo, socket.create_connection, subprocess.Popen.__init__)
        for o, a in zip(orig, after):
            self.assertIs(o, a, "the guard put the original member back")

    def test_11_backend_is_untouched(self):
        with G.no_network():
            G.build()
        self.assertEqual(backend_state(), self.before, "backend\\ (every .py, and the list of files) is the same after generating")
        self.assertFalse([k for k in self.before if k.endswith(".pyc") or k == "__pycache__"], "no bytecode under backend\\")

    def test_12_build_is_deterministic(self):
        with G.no_network():
            again = G.build()
        self.assertEqual(G.dumps(again), G.dumps(self.doc))

    def test_13_dumps_is_strict_json(self):
        text = G.dumps(self.doc)
        back = json.loads(text, parse_constant=lambda c: self.fail("NaN/Infinity in the golden file: " + c))
        self.assertEqual(back, json.loads(json.dumps(self.doc)))
        text.encode("utf-8")

    # ---- --check and drift
    def test_20_check_is_clean_on_disk(self):
        self.assertEqual(G.compare(self.doc), [])

    def test_21_main_check_exit_and_last_line(self):
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            rc = G.main(["--check"])
        lines = buf.getvalue().strip().splitlines()
        self.assertEqual(rc, 0, buf.getvalue())
        self.assertRegex(lines[-1], r"^SCORE_GOLDEN_OK cases=\d+$")
        self.assertGreaterEqual(int(lines[-1].split("=")[1]), 120)

    def test_22_selfcheck_changed_value_is_drift(self):
        bad = json.loads(G.dumps(self.doc))
        bad["cases"][0]["expect"]["score"] += 1
        p = self.tmp_file("bad_value.json", json.dumps(bad, ensure_ascii=False))
        drift = G.compare(self.doc, path=p)
        self.assertTrue(any(d.startswith("GOLDEN_DRIFT cases " + self.doc["cases"][0]["id"]) for d in drift), drift)

    def test_23_selfcheck_changed_key_order_is_drift(self):
        bad = json.loads(G.dumps(self.doc))
        e = bad["cases"][0]["expect"]
        bad["cases"][0]["expect"] = {k: e[k] for k in sorted(e)}
        p = self.tmp_file("bad_order.json", json.dumps(bad, ensure_ascii=False))
        self.assertTrue(G.compare(self.doc, path=p))

    def test_24_selfcheck_missing_file_and_broken_json_are_drift(self):
        self.assertTrue(G.compare(self.doc, path=os.path.join(self.tmp, "nope.json"))[0].startswith("GOLDEN_DRIFT missing file"))
        p = self.tmp_file("broken.json", '{"v":1,"cases":[')
        self.assertTrue(G.compare(self.doc, path=p)[0].startswith("GOLDEN_DRIFT file is not valid JSON"))
        p2 = self.tmp_file("short.json", json.dumps({"v": 1, "ok_prob": 0.45, "cases": []}))
        self.assertGreaterEqual(len(G.compare(self.doc, path=p2)), 3)

    def test_25_selfcheck_changed_table_is_drift(self):
        with open(G.CORE_PATH, "r", encoding="utf-8") as f:
            core = f.read()
        tables = G.nfkc_tables_text()
        self.assertIn(tables, core)
        broken = core.replace("0xAA: \"a\"", "0xAA: \"b\"", 1)
        self.assertNotEqual(broken, core)
        p = self.tmp_file("core_broken.gd", broken)
        drift = G.compare(self.doc, core_path=p)
        self.assertTrue(any(d.startswith("GOLDEN_DRIFT tables") for d in drift), drift)
        self.assertEqual(G.compare(self.doc, core_path=self.tmp_file("core_ok.gd", core)), [])

    def test_26_selfcheck_server_rule_change_is_drift(self):
        """the server's threshold changes in memory: the golden file on disk is no longer what the server gives"""
        S = self.S
        old = S.OK_PROB
        try:
            S.OK_PROB = 0.40
            with G.no_network():
                changed = G.build()
        finally:
            S.OK_PROB = old
        drift = G.compare(changed)
        self.assertTrue(drift, "a changed threshold must be reported")
        self.assertTrue(any(d.startswith("GOLDEN_DRIFT cases ") for d in drift))
        self.assertEqual(S.OK_PROB, old)

    def test_27_main_usage_error_is_2(self):
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            self.assertEqual(G.main(["--bogus"]), 2)
        self.assertIn("usage", buf.getvalue())

    def test_28_main_tables_prints_the_tables(self):
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            self.assertEqual(G.main(["--tables"]), 0)
        self.assertEqual(buf.getvalue(), G.nfkc_tables_text())

    def test_29_write_goes_only_to_the_given_path(self):
        p = os.path.join(self.tmp, "sub", "out.json")
        G.write(self.doc, path=p)
        with open(p, "r", encoding="utf-8") as f:
            self.assertEqual(f.read(), G.dumps(self.doc))
        self.assertEqual(G.compare(self.doc, path=p), [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
