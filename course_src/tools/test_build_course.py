# -*- coding: utf-8 -*-
"""build_course.py: determinism, hashes, refusal on lint failures, and the output format the app loader (E1) reads (K1-5)."""
import hashlib
import json
import re
import unittest
from pathlib import Path

import tool_support as ts
import build_course as bc


def build(src, out, *args):
    return ts.cli("build_course.py", "--in", src, "--out", out, *args)


def read(out, name):
    return json.loads((Path(out) / name).read_text(encoding="utf-8"))


class Build(unittest.TestCase):
    def setUp(self):
        self.tmp = ts.tmpdir()
        self.root = Path(self.tmp.name)
        self.src = self.root / "src"
        ts.write_course(self.src)

    def tearDown(self):
        self.tmp.cleanup()

    def manifest_hashes(self, out):
        m = read(out, "course_manifest.json")
        return {f["path"]: f["sha256"] for f in m["files"]}

    def test_two_builds_have_equal_manifests_and_files(self):
        o1, o2 = self.root / "o1", self.root / "o2"
        self.assertEqual(build(self.src, o1)[0], 0)
        self.assertEqual(build(self.src, o2)[0], 0)
        self.assertEqual(self.manifest_hashes(o1), self.manifest_hashes(o2))
        for p in sorted(o1.iterdir()):
            self.assertEqual(p.read_bytes(), (o2 / p.name).read_bytes(), p.name)

    def test_one_changed_character_changes_that_files_hash(self):
        o1, o2 = self.root / "o1", self.root / "o2"
        build(self.src, o1)
        p = self.src / "weeks" / "w001.json"
        p.write_text(p.read_text(encoding="utf-8").replace("안녕하세요, 민.", "안녕하세요, 민!", 1), encoding="utf-8")
        self.assertEqual(build(self.src, o2)[0], 0)
        h1, h2 = self.manifest_hashes(o1), self.manifest_hashes(o2)
        changed = {k for k in h1 if h1[k] != h2[k]}
        self.assertIn("en_sentences.json", changed)
        self.assertNotIn("en_dialogues.json", changed)
        self.assertNotIn("en_lexicon.json", changed)
        self.assertNotIn("en_patterns.json", changed)

    def test_manifest_matches_the_files(self):
        out = self.root / "o"
        code, lines, _ = build(self.src, out)
        self.assertEqual(code, 0)
        self.assertRegex(lines[-1], r"^BUILD_OK files=7 bytes=\d+")
        m = read(out, "course_manifest.json")
        self.assertEqual(m["v"], 1)
        self.assertEqual([f["path"] for f in m["files"]], sorted(bc.FILES))
        for f in m["files"]:
            b = (out / f["path"]).read_bytes()
            self.assertEqual(f["bytes"], len(b))
            self.assertEqual(f["sha256"], hashlib.sha256(b).hexdigest())
            self.assertEqual(f["records"], len(next(v for k, v in json.loads(b.decode("utf-8")).items() if isinstance(v, list))))

    def test_files_are_compact_one_line_utf8_json(self):
        out = self.root / "o"
        build(self.src, out)
        for p in out.iterdir():
            raw = p.read_bytes()
            self.assertTrue(raw.endswith(b"\n") and raw.count(b"\n") == 1, p.name)
            self.assertNotIn(b"\r", raw)
            self.assertNotIn(b": ", raw)
            self.assertIn("ko", raw.decode("utf-8")) if p.name.startswith("en_s") else None

    def test_no_timestamp_in_the_manifest(self):
        out = self.root / "o"
        build(self.src, out)
        self.assertNotIn("built", read(out, "course_manifest.json"))

    def test_app_loader_format(self):
        """The shapes E1's CourseData reads: {"v":1,"lang":"en","<key>":[...]}, manifest {"v":1,"files":[...]}, integer fields."""
        out = self.root / "o"
        build(self.src, out)
        keys = {"en_weeks.json": "weeks", "en_lexicon.json": "words", "en_patterns.json": "patterns", "en_sentences.json": "sentences",
                "en_dialogues.json": "dialogues", "en_speak_prompts.json": "prompts"}
        for name, key in keys.items():
            d = read(out, name)
            self.assertEqual((d["v"], d["lang"]), (1, "en"), name)
            self.assertIsInstance(d[key], list, name)
        for w in read(out, "en_weeks.json")["weeks"]:
            for k in ("w", "n", "k", "stage", "legacy_stage"):
                self.assertIs(type(w[k]), int)
            self.assertEqual(len(w["days"]), 7)
            self.assertEqual(set(w), {"w", "n", "k", "stage", "legacy_stage", "title_ko", "can_do", "scene", "words", "patterns", "dialogue",
                                      "ladder", "days", "check", "minutes", "notes"})
        for x in read(out, "en_lexicon.json")["words"]:
            self.assertIs(type(x["o"]), int)
            self.assertEqual(x["o"] // 10, next(w["w"] for w in read(out, "en_weeks.json")["weeks"]
                                                if x["id"] in w["words"]["new"] + w["words"]["passive"]))
        for s in read(out, "en_sentences.json")["sentences"]:
            self.assertIs(type(s["o"]), int)
            self.assertIs(type(s["tid"]), int)
        for d in read(out, "en_dialogues.json")["dialogues"]:
            self.assertIs(type(d["w"]), int)
            self.assertTrue(all(type(l["o"]) is int for l in d["lines"]))

    def test_speak_prompts_are_grouped_by_month_like_the_loader_fixture(self):
        out = self.root / "o"
        build(self.src, out)
        groups = read(out, "en_speak_prompts.json")["prompts"]
        self.assertEqual([g["month"] for g in groups], [1])
        self.assertEqual(len(groups[0]["prompts"]), 3)
        self.assertEqual(set(groups[0]["prompts"][0]), {"id", "kind", "en", "ko", "say", "expect_any", "o"})

    def test_lexicon_forms_get_an_o_and_say_is_kept(self):
        def mut(d):
            ts.find(d, 1, "words", "w0008")["forms"] = [{"f": "names", "pat": "p_good_x"}]
        src = self.root / "s2"
        ts.write_course(src, mut)
        out = self.root / "o"
        self.assertEqual(build(src, out)[0], 0)
        w = next(x for x in read(out, "en_lexicon.json")["words"] if x["id"] == "w0008")
        self.assertEqual(w["forms"], [{"f": "names", "pat": "p_good_x", "o": 14}])
        s = next(x for x in read(out, "en_sentences.json")["sentences"] if x["id"] == "s0107")
        self.assertEqual(s["say"], "My number is three.")
        self.assertEqual(s["words"], sorted(s["words"]))
        self.assertIn("w0105", s["words"])

    def test_derived_week_fields(self):
        out = self.root / "o"
        build(self.src, out)
        w1 = read(out, "en_weeks.json")["weeks"][0]
        self.assertEqual(w1["words"]["new"][:3], ["w0001", "w0002", "w0003"])
        self.assertEqual([d["kind"] for d in w1["days"]], ["new", "new", "new", "new", "speak", "check", "free"])
        self.assertEqual(w1["days"][2]["patterns"], ["p_my_name"])
        self.assertEqual(w1["minutes"], {"new": 18, "review": 5, "listen": 12, "speak": 10})
        self.assertEqual(w1["ladder"], {"repeat": True, "substitute": False, "script": False, "mission": "none", "free": "none"})
        self.assertEqual(w1["check"], {"items": 12, "pass": 80, "month": False})
        w4 = read(out, "en_weeks.json")["weeks"][2]
        self.assertTrue(w4["check"]["month"])
        self.assertEqual(w4["notes"][0]["kind"], "spelling")

    def test_ladder_table(self):
        got = {w: bc.ladder_of(w) for w in (1, 2, 8, 13, 17, 24, 25, 33, 56, 57, 72)}
        self.assertEqual((got[1]["substitute"], got[2]["substitute"]), (False, True))
        self.assertEqual((got[2]["script"], got[8]["script"]), (False, True))
        self.assertEqual([got[w]["mission"] for w in (8, 13, 24, 25)], ["none", "script", "script", "ai"])
        self.assertEqual([got[w]["free"] for w in (13, 17, 32 if 32 in got else 24, 33, 56, 57)], ["none", "guided", "guided", "free", "free", "open"])

    def test_refuses_to_write_when_the_lint_fails(self):
        out = self.root / "o"
        bad = ts.FIX / "bad_order"
        code, lines, _ = build(bad, out)
        self.assertEqual(code, 1)
        self.assertEqual(lines[0], "CHECK_FAIL ORDER")
        self.assertEqual(lines[-1], "BUILD_FAIL check_failed (nothing written)")
        self.assertFalse(out.exists())

    def test_every_bad_fixture_is_refused(self):
        for name in ts.mf.BAD:
            with self.subTest(name=name):
                out = self.root / ("o_" + name)
                code, lines, _ = build(ts.FIX / name, out)
                self.assertEqual(code, 1)
                self.assertFalse(out.exists())

    def test_check_only_writes_nothing(self):
        out = self.root / "o"
        code, lines, _ = ts.cli("build_course.py", "--in", self.src, "--check")
        self.assertEqual(code, 0)
        self.assertRegex(lines[-1], r"^BUILD_CHECK_OK files=7")
        self.assertFalse(out.exists())

    def test_out_is_required_without_check(self):
        code, lines, _ = ts.cli("build_course.py", "--in", self.src)
        self.assertEqual(code, 1)

    def test_weeks_range(self):
        out = self.root / "o"
        code, lines, _ = build(self.src, out, "--weeks", "1-2")
        self.assertEqual(code, 0, lines)
        self.assertEqual([w["w"] for w in read(out, "en_weeks.json")["weeks"]], [1, 2])
        m = read(out, "course_manifest.json")
        self.assertEqual(m["weeks"], [1, 2])
        code, lines, _ = build(self.src, self.root / "o3", "--weeks", "1-3")
        self.assertEqual(code, 1)        # week 3 has no file

    def test_lexicon_from_skeleton_builds_the_same_data(self):
        o1, o2 = self.root / "o1", self.root / "o2"
        build(self.src, o1)
        self.assertEqual(build(self.src, o2, "--lexicon-from", "skeleton")[0], 0)
        self.assertEqual(self.manifest_hashes(o1), self.manifest_hashes(o2))

    def test_output_has_no_personal_paths(self):
        out = self.root / "o"
        build(self.src, out)
        for p in out.iterdir():
            self.assertIsNone(re.search(r"C:\\\\Users|rtyu|@", p.read_text(encoding="utf-8")), p.name)

    def test_duplicate_ids_and_out_of_range_weeks_are_errors(self):
        def dup(d):
            ts.find(d, 2, "words", "w0101")["id"] = "w0001"
        src = self.root / "d"
        ts.write_course(src, dup)
        code, lines, _ = build(src, self.root / "od")
        self.assertEqual(code, 1)
        self.assertEqual(lines[0], "CHECK_FAIL SCHEMA")
        src2 = self.root / "d2"
        ts.write_course(src2)
        (src2 / "weeks" / "w073.json").write_text("{}", encoding="utf-8")
        code, lines, _ = build(src2, self.root / "od2")
        self.assertEqual(code, 1)

    def test_the_committed_fixture_builds(self):
        out = self.root / "o"
        self.assertEqual(build(ts.FIX / "good_mini", out)[0], 0)


if __name__ == "__main__":
    unittest.main()
