# -*- coding: utf-8 -*-
"""sample_sheet.py (K1-6) and tatoeba_fit.py."""
import csv
import sqlite3
import unittest
from pathlib import Path

import tool_support as ts
import sample_sheet as ss
import tatoeba_fit as tf
import course_common as cc


def rows_of(path):
    with open(path, "r", encoding="utf-8-sig", newline="") as f:
        return list(csv.reader(f))


class SampleSheet(unittest.TestCase):
    def setUp(self):
        self.tmp = ts.tmpdir()
        self.root = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def sheet(self, n, seed, name="s.csv"):
        out = self.root / name
        code, lines, _ = ts.cli("sample_sheet.py", "--in", ts.FIX / "good_mini", "--n", n, "--seed", seed, "--out", out)
        self.assertEqual(code, 0, lines)
        return out, lines

    def test_header_and_row_count(self):
        out, lines = self.sheet(20, 7)
        rows = rows_of(out)
        self.assertEqual(rows[0], ["id", "type", "en", "ko", "say", "note", "verdict"])
        self.assertEqual(len(rows) - 1, 20)
        self.assertRegex(lines[-1], r"^SAMPLE_OK rows=20 ")
        self.assertTrue(all(r[6] == "" for r in rows[1:]))

    def test_strata_within_one_of_the_shares(self):
        out, _ = self.sheet(20, 7)
        kinds = [r[1] for r in rows_of(out)[1:]]
        for kind, share in ss.SHARES:
            self.assertLessEqual(abs(kinds.count(kind) - 20 * share / 300), 1, kind)

    def test_same_seed_same_file_other_seed_other_file(self):
        a, _ = self.sheet(20, 7, "a.csv")
        b, _ = self.sheet(20, 7, "b.csv")
        c, _ = self.sheet(20, 8, "c.csv")
        self.assertEqual(a.read_bytes(), b.read_bytes())
        self.assertNotEqual(a.read_bytes(), c.read_bytes())

    def test_fewer_items_than_requested_gives_all(self):
        out, _ = self.sheet(500, 1)
        total = 23 + 5 + 38 + 9
        self.assertEqual(len(rows_of(out)) - 1, total)

    def test_ids_are_unique_and_exist(self):
        out, _ = self.sheet(40, 3)
        ids = [r[0] for r in rows_of(out)[1:]]
        self.assertEqual(len(ids), len(set(ids)))

    def test_allocation_redistributes_a_short_stratum(self):
        q = ss.allocate(30, {"word": 2, "sentence": 100, "dialogue_line": 100, "grammar": 100})
        self.assertEqual(q["word"], 2)
        self.assertEqual(sum(q.values()), 30)
        q = ss.allocate(300, {"word": 1000, "sentence": 1000, "dialogue_line": 1000, "grammar": 1000})
        self.assertEqual(q, {"word": 90, "sentence": 120, "dialogue_line": 50, "grammar": 40})

    def test_bad_arguments_fail(self):
        code, lines, _ = ts.cli("sample_sheet.py", "--in", self.root / "nope", "--n", 5, "--seed", 1, "--out", self.root / "x.csv")
        self.assertEqual(code, 1)
        code, lines, _ = ts.cli("sample_sheet.py", "--in", ts.FIX / "good_mini", "--n", 0, "--seed", 1, "--out", self.root / "x.csv")
        self.assertEqual(code, 1)
        self.assertFalse((self.root / "x.csv").exists())


class TatoebaFit(unittest.TestCase):
    def setUp(self):
        self.tmp = ts.tmpdir()
        self.root = Path(self.tmp.name)
        self.db = self.root / "t.sqlite"
        con = sqlite3.connect(str(self.db))
        con.execute("CREATE TABLE sent(id INTEGER PRIMARY KEY, lang TEXT NOT NULL, text TEXT NOT NULL, ko TEXT, tr TEXT, k INTEGER NOT NULL)")
        rows = [(1, "en", "Hello.", "안녕하세요.", None, 1), (2, "en", "Good morning, Min.", "좋은 아침이에요, 민.", None, 1),
                (3, "en", "Hello, friend.", "안녕하세요, 친구.", None, 1), (4, "en", "Hello, zzyx.", "안녕, 어쩌고.", None, 1),
                (5, "en", "Hello 5.", "안녕 5.", None, 1), (6, "en", "Thanks.", None, None, 1), (7, "ja", "Hello.", "안녕하세요.", None, 1),
                (8, "en", "Thanks.", "gomawo", None, 1)]
        con.executemany("INSERT INTO sent VALUES (?,?,?,?,?,?)", rows)
        con.commit()
        con.close()
        self.src = self.root / "m"
        ts.write_course(self.src)

    def tearDown(self):
        self.tmp.cleanup()

    def test_candidates_per_week(self):
        sents = tf.load_sentences(self.db)
        self.assertEqual({s[0] for s in sents}, {1, 2, 3, 4})        # no digits, Korean with Hangul, English rows only
        lex = cc.build_lexicon(cc.Course(str(self.src)).load())
        res = tf.fit(sents, lex, [1, 2, 4])
        self.assertEqual((res[1]["cum"], res[1]["new"]), (2, 2))      # "Hello." and "Good morning, Min."
        self.assertEqual((res[2]["cum"], res[2]["new"]), (2, 0))
        self.assertEqual((res[4]["cum"], res[4]["new"]), (3, 1))      # "Hello, friend." appears with week 4

    def test_cli_output(self):
        code, lines, _ = ts.cli("tatoeba_fit.py", "--in", self.src, "--db", self.db, "--weeks", "1-4", "--show", 1)
        self.assertEqual(code, 0, lines)
        self.assertIn("FIT week=1 cum=2 new=2", lines)
        self.assertIn("FIT week=4 cum=3 new=1", lines)
        self.assertRegex(lines[-1], r"^FIT_OK weeks=1-4 database_sentences=4$")

    def test_json_output(self):
        out = self.root / "o.json"
        code, lines, _ = ts.cli("tatoeba_fit.py", "--in", self.src, "--db", self.db, "--weeks", "1-2", "--json", out)
        self.assertEqual(code, 0)
        self.assertIn('"cum": 2', out.read_text(encoding="utf-8"))

    def test_missing_database_is_reported_not_zero(self):
        code, lines, _ = ts.cli("tatoeba_fit.py", "--in", self.src, "--db", self.root / "none.sqlite")
        self.assertEqual(code, 1)
        self.assertIn("not verified", lines[0])

    def test_database_is_not_modified_and_opened_read_only(self):
        before = self.db.read_bytes()
        tf.load_sentences(self.db)
        self.assertEqual(before, self.db.read_bytes())
        con = sqlite3.connect(self.db.resolve().as_uri() + "?mode=ro", uri=True)
        with self.assertRaises(sqlite3.OperationalError):
            con.execute("INSERT INTO sent VALUES (99,'en','x','y',NULL,1)")
        con.close()

    def test_lexicon_from_skeleton(self):
        code, lines, _ = ts.cli("tatoeba_fit.py", "--in", self.src, "--db", self.db, "--lexicon-from", "skeleton")
        self.assertEqual(code, 0, lines)
        self.assertIn("FIT week=1 cum=2 new=2", lines)


if __name__ == "__main__":
    unittest.main()
